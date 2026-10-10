import XCTest
import AppKit

// Slice T0: the Teri tabbed surface, its Todos tab, and the view state that
// survives a relaunch. Everything is headless: the real `TeriSurfaceView` goes
// into an offscreen window that is never shown, driven through its test-visible
// members and real key events. Nothing here asserts on pixels, and nothing
// waits a fixed time: state changes are polled for on the run loop.

// MARK: - Helpers

/// Pump the main run loop until `condition` holds (true) or `timeout` passes (false).
@discardableResult
private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return true
}

private func settle(_ seconds: TimeInterval = 0.1) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

private final class FrameLog {
    var frames: [WorkClientMessage] = []
    var detailRequests: [(requestId: String, itemId: String)] {
        frames.compactMap {
            if case .detailRequest(let r, let i) = $0 { return (r, i) }
            return nil
        }
    }
}

private final class FocusableView: NSView {
    override var acceptsFirstResponder: Bool { true }
}

private func keyEvent(_ chars: String, code: UInt16, window: NSWindow?,
                      flags: NSEvent.ModifierFlags = .command) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                     windowNumber: window?.windowNumber ?? 0, context: nil,
                     characters: chars, charactersIgnoringModifiers: chars,
                     isARepeat: false, keyCode: code)!
}

/// Two todos: a P1 that is long overdue and a P3 due far in the future, deliberately
/// seeded in the "wrong" order (the surface must sort).
private func seedTodos(_ store: WorkStore, state: SourceState = .fresh) {
    store.apply(snapshot: .todos, group: nil, items: [
        WorkTestSupport.todo(1, "Write the quarterly report", status: "open", priority: 3, due: "2099-12-31",
                             createdAt: "2026-10-01T08:00:00Z"),
        WorkTestSupport.todo(2, "Fix payment webhook", status: "in_progress", priority: 1, due: "2000-01-01",
                             createdAt: "2026-10-01T08:00:00Z", linked: ["CORE-1"],
                             searchText: "Fix payment webhook\nCheck the retry backoff."),
    ])
    store.apply(status: SourceStatus(source: .todos, state: state, count: 2))
}

private func comingSoon(_ source: WorkSource) -> SourceStatus {
    SourceStatus(source: source, state: .notConfigured, reason: "Coming soon")
}

// MARK: - Todos row content (pure)

final class TeriTodosRowContentTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.locale = Locale(identifier: "en_US_POSIX")
        return c
    }()
    /// Friday 9 October 2026, mid-afternoon UTC.
    private let now = ISO8601DateFormatter().date(from: "2026-10-09T15:00:00Z")!

    private func content(_ item: WorkItem) -> WorkRowContent {
        TeriTodosTab.rowContent(for: item, now: now, calendar: calendar)
    }

    func testPriorityIsShownAsTextNotColourAlone() {
        for p in 1...5 {
            XCTAssertEqual(content(WorkTestSupport.todo(p, "t", priority: p)).priorityText, "P\(p)")
        }
        XCTAssertNil(content(WorkTestSupport.todo(9, "t", priority: nil)).priorityText)
    }

    func testTheTitleIsShownVerbatim() {
        XCTAssertEqual(content(WorkTestSupport.todo(1, "Reply to Dana about café budget")).title,
                       "Reply to Dana about café budget")
    }

    func testAnOverdueTodoSaysHowManyDaysOverdue() {
        XCTAssertEqual(content(WorkTestSupport.todo(1, "t", due: "2026-10-07")).dueText, "Overdue by 2 days")
        XCTAssertTrue(content(WorkTestSupport.todo(1, "t", due: "2026-10-08")).dueText?.hasPrefix("Overdue by 1 day") ?? false)
    }

    func testATodoDueTodayIsDueToday() {
        XCTAssertEqual(content(WorkTestSupport.todo(1, "t", due: "2026-10-09")).dueText, "Due today")
    }

    func testATodoDueLaterThisWeekNamesTheWeekday() {
        XCTAssertEqual(content(WorkTestSupport.todo(1, "t", due: "2026-10-12")).dueText, "Due Mon")   // +3 days
        XCTAssertEqual(content(WorkTestSupport.todo(1, "t", due: "2026-10-13")).dueText, "Due Tue")   // +4 days
    }

    func testATodoDueFurtherOutShowsTheDate() {
        XCTAssertEqual(content(WorkTestSupport.todo(1, "t", due: "2026-10-29")).dueText, "Due Oct 29")
    }

    func testATodoWithNoDueDateHasNoDueText() {
        XCTAssertNil(content(WorkTestSupport.todo(1, "t", due: nil)).dueText)
    }

    func testStatusIsSpelledOutForBlockedAndInProgressTodos() {
        XCTAssertTrue(content(WorkTestSupport.todo(1, "t", status: "blocked")).statusText?.lowercased().contains("blocked") ?? false)
        XCTAssertTrue(content(WorkTestSupport.todo(1, "t", status: "in_progress")).statusText?.lowercased().contains("progress") ?? false)
    }

    func testTheAccessibilityLabelNamesTheSourceTypeTitlePriorityAndAge() {
        let item = WorkTestSupport.todo(1, "Fix payment webhook", priority: 1, due: "2026-10-12",
                                        createdAt: "2026-10-06T15:00:00Z")   // 3 days before `now`
        let label = content(item).accessibilityLabel

        XCTAssertTrue(label.contains("Todo"), label)
        XCTAssertTrue(label.contains("Fix payment webhook"), label)
        XCTAssertTrue(label.contains("P1") || label.lowercased().contains("priority 1"), label)
        XCTAssertTrue(label.contains("3 days"), "age comes from created_at: \(label)")
    }

    func testTheAgeFallsBackToUpdatedAtWhenThereIsNoCreatedAt() {
        let item = WorkTestSupport.todo(1, "Call the plumber", priority: 2, updatedAt: "2026-10-04T15:00:00Z")
        XCTAssertTrue(content(item).accessibilityLabel.contains("5 days"), content(item).accessibilityLabel)
    }

    func testAnItemWithNoDatesAndNoPriorityStillGetsAUsefulLabel() {
        let label = content(WorkTestSupport.todo(1, "Bare todo", priority: nil)).accessibilityLabel
        XCTAssertTrue(label.contains("Todo"))
        XCTAssertTrue(label.contains("Bare todo"))
    }
}

// MARK: - Tabs and persisted view state

final class TeriViewStateTests: XCTestCase {
    private var suites: [String] = []

    private func makeDefaults() -> UserDefaults {
        let name = "nostromo.tests.teriViewState.\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    override func tearDown() {
        for name in suites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        suites.removeAll()
        super.tearDown()
    }

    // MARK: Tabs

    func testTabsAreInSurfaceOrderWithTheirTitlesAndSources() {
        XCTAssertEqual(TeriTab.allCases, [.picks, .todos, .jira, .sentry, .repoDocs])
        XCTAssertEqual(TeriTab.allCases.map(\.title), ["Picks", "Todos", "Jira", "Sentry", "Repo docs"])
        XCTAssertNil(TeriTab.picks.source)
        XCTAssertEqual(TeriTab.todos.source, .todos)
        XCTAssertEqual(TeriTab.jira.source, .jira)
        XCTAssertEqual(TeriTab.sentry.source, .sentry)
        XCTAssertEqual(TeriTab.repoDocs.source, .repoDocs)
    }

    func testTabIdsAreTheDeepLinkIds() {
        XCTAssertEqual(TeriTab.allCases.map(\.rawValue), ["picks", "todos", "jira", "sentry", "repo_docs"])
    }

    // MARK: Round trip

    func testStateRoundTripsThroughAUserDefaultsSuite() {
        let defaults = makeDefaults()
        var state = TeriViewState()
        state.selectedTab = .jira
        state[.todos].filter.query = "café"
        state[.todos].filter.statuses = ["open", "blocked"]
        state[.todos].sort = .title
        state[.todos].selectedItemId = "todo:2"
        state[.repoDocs].collapsedGroups = ["alpha", "beta"]
        state[.repoDocs].filter.hasSeverity = true

        state.save(to: defaults)
        let loaded = TeriViewState.load(from: defaults)

        XCTAssertEqual(loaded, state)
        XCTAssertEqual(loaded.selectedTab, .jira)
        XCTAssertEqual(loaded[.todos].filter.query, "café")
        XCTAssertEqual(loaded[.todos].sort, .title)
        XCTAssertEqual(loaded[.todos].selectedItemId, "todo:2")
        XCTAssertEqual(loaded[.repoDocs].collapsedGroups, ["alpha", "beta"])
        XCTAssertEqual(loaded[.repoDocs].filter.hasSeverity, true)
    }

    func testAnUntouchedTabHasTheDefaultViewState() {
        let state = TeriViewState()
        XCTAssertNil(state.selectedTab)
        XCTAssertEqual(state[.sentry], TeriTabViewState())
        XCTAssertEqual(state[.sentry].sort, .newest)
        XCTAssertEqual(state[.sentry].filter, WorkFilter())
        XCTAssertTrue(state[.sentry].collapsedGroups.isEmpty)
        XCTAssertNil(state[.sentry].selectedItemId)
    }

    func testStateIsStoredUnderTheVersionedKeyAsJSONKeyedByTabName() throws {
        XCTAssertEqual(TeriViewState.defaultsKey, "nostromo.teri.viewState.v1")
        let defaults = makeDefaults()
        var state = TeriViewState()
        state.selectedTab = .repoDocs
        state[.repoDocs].sort = .oldest
        state.save(to: defaults)

        let data = try XCTUnwrap(defaults.data(forKey: TeriViewState.defaultsKey))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let tabs = try XCTUnwrap(obj["tabs"] as? [String: Any], "tabs is an object keyed by the tab's name")
        XCTAssertNotNil(tabs["repo_docs"])
    }

    func testMissingOrCorruptStoredStateGivesAnEmptyStateNotACrash() {
        let defaults = makeDefaults()
        XCTAssertEqual(TeriViewState.load(from: defaults), TeriViewState(), "nothing stored")

        defaults.set(Data([0xFF, 0x00, 0x13, 0x37]), forKey: TeriViewState.defaultsKey)
        XCTAssertEqual(TeriViewState.load(from: defaults), TeriViewState(), "garbage bytes")

        defaults.set("not even data", forKey: TeriViewState.defaultsKey)
        XCTAssertEqual(TeriViewState.load(from: defaults), TeriViewState(), "wrong type")

        defaults.set(Data(#"{"selectedTab": 12, "tabs": []}"#.utf8), forKey: TeriViewState.defaultsKey)
        XCTAssertEqual(TeriViewState.load(from: defaults), TeriViewState(), "valid JSON, wrong shape")
    }

    func testTabsFromANewerVersionAreIgnoredWithoutLosingTheKnownOnes() throws {
        let defaults = makeDefaults()
        var state = TeriViewState()
        state[.todos].selectedItemId = "todo:1"
        state.save(to: defaults)
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(
            with: try XCTUnwrap(defaults.data(forKey: TeriViewState.defaultsKey))) as? [String: Any])
        var tabs = try XCTUnwrap(obj["tabs"] as? [String: Any])
        tabs["a_tab_from_the_future"] = tabs["todos"]
        obj["tabs"] = tabs
        defaults.set(try JSONSerialization.data(withJSONObject: obj), forKey: TeriViewState.defaultsKey)

        XCTAssertEqual(TeriViewState.load(from: defaults)[.todos].selectedItemId, "todo:1")
    }

    // MARK: Store

    func testTheStoreStartsFromWhatWasPersisted() {
        let defaults = makeDefaults()
        var seeded = TeriViewState()
        seeded.selectedTab = .sentry
        seeded.save(to: defaults)

        XCTAssertEqual(TeriViewStateStore(defaults: defaults).state.selectedTab, .sentry)
    }

    func testAnUpdateIsVisibleAtOnceButPersistedOnlyOnFlushWhenTheDebounceIsLong() {
        let defaults = makeDefaults()
        let store = TeriViewStateStore(defaults: defaults, debounce: 60)

        store.update { $0.selectedTab = .jira; $0[.jira].filter.query = "crash" }

        XCTAssertEqual(store.state.selectedTab, .jira, "in memory immediately")
        XCTAssertEqual(store.state[.jira].filter.query, "crash")
        XCTAssertEqual(TeriViewState.load(from: defaults), TeriViewState(), "not written yet")

        store.flush()

        XCTAssertEqual(TeriViewState.load(from: defaults), store.state, "flush persists right now")
    }

    func testADebouncedUpdateEventuallyLandsInDefaults() {
        let defaults = makeDefaults()
        let store = TeriViewStateStore(defaults: defaults, debounce: 0.05)

        store.update { $0.selectedTab = .todos }
        store.update { $0[.todos].selectedItemId = "todo:9" }

        XCTAssertTrue(waitUntil { TeriViewState.load(from: defaults)[.todos].selectedItemId == "todo:9" },
                      "the debounced save never landed")
        XCTAssertEqual(TeriViewState.load(from: defaults).selectedTab, .todos, "both updates are in the saved state")
    }
}

// MARK: - The surface

final class TeriSurfaceViewTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for name in suites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        suites.removeAll()
        super.tearDown()
    }

    private struct Rig {
        let store: WorkStore
        let defaults: UserDefaults
        let center: NotificationCenter
        let window: RigWindow
        let surface: TeriSurfaceView
        let log: FrameLog
    }

    private func makeDefaults() -> UserDefaults {
        let name = "nostromo.tests.teriSurface.\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    /// A real surface in an offscreen window. `seed` runs before the surface exists
    /// (the app-relaunch case: data already in the store when the view appears).
    private func makeRig(defaults: UserDefaults? = nil,
                         seed: (WorkStore) -> Void = { _ in }) -> Rig {
        let store = WorkStore()
        let log = FrameLog()
        store.sendFrame = { log.frames.append($0) }
        seed(store)
        let defaults = defaults ?? makeDefaults()
        let center = NotificationCenter()
        let window = makeRigWindow(self)
        let surface = TeriSurfaceView(store: store, defaults: defaults, center: center)
        surface.frame = window.contentView!.bounds
        surface.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(surface)
        surface.layoutSubtreeIfNeeded()
        return Rig(store: store, defaults: defaults, center: center, window: window, surface: surface, log: log)
    }

    private func titles(_ rows: [WorkRowContent]) -> [String] { rows.map(\.title) }

    // MARK: Todos tab

    func testTheTodosTabShowsItsCountAndListsTheP1First() {
        let rig = makeRig(seed: { seedTodos($0) })
        rig.surface.select(.todos)

        XCTAssertEqual(rig.surface.selectedTab, .todos)
        XCTAssertEqual(rig.surface.tabButtonTitle(.todos), "Todos 2")
        XCTAssertTrue(waitUntil { rig.surface.rowTexts.count == 2 })
        let first = rig.surface.rowTexts[0]
        XCTAssertEqual(first.title, "Fix payment webhook", "P1 sorts above P3 even though it was seeded second")
        XCTAssertEqual(first.priorityText, "P1")
        XCTAssertNotNil(first.dueText)
        XCTAssertTrue(first.dueText?.hasPrefix("Overdue") ?? false, "due in 2000: \(String(describing: first.dueText))")
        XCTAssertTrue(first.accessibilityLabel.contains("Todo"))
        XCTAssertTrue(first.accessibilityLabel.contains("Fix payment webhook"))
        XCTAssertTrue(first.accessibilityLabel.contains("P1") || first.accessibilityLabel.lowercased().contains("priority 1"))
        XCTAssertEqual(rig.surface.rowTexts[1].priorityText, "P3")
        XCTAssertEqual(titles(rig.surface.rowTexts), ["Fix payment webhook", "Write the quarterly report"])
    }

    func testTodosArrivingAfterTheViewExistsAreShown() {
        let rig = makeRig()
        rig.surface.select(.todos)
        XCTAssertTrue(rig.surface.rowTexts.isEmpty)

        seedTodos(rig.store)

        XCTAssertTrue(waitUntil { rig.surface.rowTexts.count == 2 }, "the list follows the store")
        XCTAssertTrue(waitUntil { rig.surface.tabButtonTitle(.todos) == "Todos 2" })
    }

    // MARK: Source states

    private func rigWithTodosState(_ state: SourceState, reason: String? = nil, withItems: Bool = false) -> Rig {
        let rig = makeRig(seed: { store in
            if withItems { seedTodos(store) }
            store.apply(status: SourceStatus(source: .todos, state: state, reason: reason,
                                             count: withItems ? 2 : 0))
        })
        rig.surface.select(.todos)
        rig.surface.layoutSubtreeIfNeeded()
        return rig
    }

    private let failingStates: [SourceState] = [.loading, .notConfigured, .unauthenticated, .rateLimited, .error]

    func testEveryNonDataStateGivesTheTodosTabItsOwnDistinctTitleWord() {
        let words = failingStates.map { rigWithTodosState($0).surface.tabButtonTitle(.todos) }

        XCTAssertEqual(Set(words).count, failingStates.count, "each state needs its own word, got \(words)")
        for title in words {
            XCTAssertTrue(title.hasPrefix("Todos "), title)
            XCTAssertNotEqual(title, "Todos 0", "a broken source must not look like an empty list")
        }
    }

    func testEveryStateThatNeedsExplainingShowsItsOwnDistinctBanner() {
        let states: [SourceState] = [.loading, .stale, .notConfigured, .unauthenticated, .rateLimited, .error]
        let messages: [String] = states.map { state in
            let rig = rigWithTodosState(state, withItems: state == .stale)
            return rig.surface.visibleBannerMessage ?? "<no banner for \(state)>"
        }

        for (state, message) in zip(states, messages) {
            XCTAssertFalse(message.hasPrefix("<no banner"), message)
            XCTAssertFalse(message.isEmpty, "\(state)")
        }
        XCTAssertEqual(Set(messages).count, states.count, "banners must differ per state: \(messages)")
    }

    func testTheBannerRepeatsTheDaemonsPlainEnglishReason() {
        let rig = rigWithTodosState(.notConfigured, reason: "Teri's todo store ~/.teri/teri.db not found")
        XCTAssertTrue(rig.surface.visibleBannerMessage?.contains("teri.db") ?? false,
                      String(describing: rig.surface.visibleBannerMessage))
        let unauth = rigWithTodosState(.unauthenticated, reason: "Jira rejected the token (401)")
        XCTAssertTrue(unauth.surface.visibleBannerMessage?.contains("Jira rejected the token (401)") ?? false)
    }

    func testAnUnconfiguredOrFailedSourceNeverLooksLikeAnEmptyList() {
        for state in failingStates {
            let rig = rigWithTodosState(state)
            XCTAssertTrue(rig.surface.rowTexts.isEmpty, "\(state)")
            XCTAssertNotNil(rig.surface.visibleBannerMessage, "\(state) must explain itself")
            XCTAssertNil(rig.surface.emptyMessage, "\(state) must not claim there is simply nothing to do")
        }
    }

    func testAStaleSourceKeepsItsItemsAndSaysTheyAreStale() {
        let rig = rigWithTodosState(.stale, reason: "database is locked", withItems: true)

        XCTAssertTrue(waitUntil { rig.surface.rowTexts.count == 2 })
        XCTAssertNotNil(rig.surface.visibleBannerMessage)
        XCTAssertEqual(rig.surface.tabButtonTitle(.todos), "Todos 2")
    }

    func testAnEmptySourceHidesTheBannerAndSaysThereIsNothingToDo() {
        let rig = rigWithTodosState(.empty)

        XCTAssertNil(rig.surface.visibleBannerMessage)
        XCTAssertFalse(rig.surface.emptyMessage?.isEmpty ?? true, "a positive empty message")
        XCTAssertTrue(rig.surface.rowTexts.isEmpty)
        XCTAssertEqual(rig.surface.tabButtonTitle(.todos), "Todos 0")
    }

    func testAFreshSourceShowsNeitherBannerNorEmptyMessage() {
        let rig = rigWithTodosState(.fresh, withItems: true)

        XCTAssertTrue(waitUntil { rig.surface.rowTexts.count == 2 })
        XCTAssertNil(rig.surface.visibleBannerMessage)
        XCTAssertNil(rig.surface.emptyMessage)
    }

    func testBeforeTheDaemonHasReportedAnythingTheTabIsLoadingNotEmpty() {
        let rig = makeRig()
        rig.surface.select(.todos)

        XCTAssertNotNil(rig.surface.visibleBannerMessage)
        XCTAssertNil(rig.surface.emptyMessage)
    }

    func testSourcesNotBuiltYetSayComingSoonInTheirTabAndShowNoCount() {
        let rig = makeRig(seed: { store in
            store.apply(status: comingSoon(.jira))
            store.apply(status: comingSoon(.sentry))
            store.apply(status: comingSoon(.repoDocs))
        })

        for tab in [TeriTab.jira, .sentry, .repoDocs] {
            let title = rig.surface.tabButtonTitle(tab)
            XCTAssertTrue(title.hasPrefix(tab.title), title)
            XCTAssertTrue(title.contains("Coming soon"), title)
            XCTAssertNil(title.rangeOfCharacter(from: .decimalDigits), "no count on a source that does not exist yet: \(title)")
        }
        rig.surface.select(.jira)
        XCTAssertTrue(rig.surface.visibleBannerMessage?.contains("Coming soon") ?? false,
                      String(describing: rig.surface.visibleBannerMessage))
    }

    func testPicksIsComingSoonUntilPicksExist() {
        let rig = makeRig()
        XCTAssertNil(rig.store.picks)
        let title = rig.surface.tabButtonTitle(.picks)
        XCTAssertTrue(title.hasPrefix("Picks"), title)
        XCTAssertTrue(title.contains("Coming soon"), title)
        XCTAssertNil(title.rangeOfCharacter(from: .decimalDigits), title)
    }

    // MARK: Detail

    func testSelectingATodoAsksTheDaemonForItsDetailAndShowsTheAnswer() {
        let rig = makeRig(seed: { seedTodos($0) })
        rig.surface.select(.todos)
        XCTAssertTrue(waitUntil { rig.surface.rowTexts.count == 2 })
        rig.log.frames.removeAll()

        rig.surface.selectItem(id: "todo:2")

        XCTAssertEqual(rig.surface.selectedItemId, "todo:2")
        let requests = rig.log.detailRequests
        XCTAssertEqual(requests.map { $0.itemId }, ["todo:2"])
        XCTAssertNotEqual(rig.surface.detailTitle, "Fix payment webhook (detail)", "not shown before the daemon answers")

        rig.store.resolve(requestId: requests[0].requestId,
                          with: .detail(.ok(WorkTestSupport.makeDetail(itemId: "todo:2", title: "Fix payment webhook (detail)",
                                                                       markdown: "Check the retry backoff."))))

        XCTAssertTrue(waitUntil { rig.surface.detailTitle == "Fix payment webhook (detail)" },
                      "detailTitle: \(String(describing: rig.surface.detailTitle))")
    }

    func testALateAnswerForAnItemYouNavigatedAwayFromDoesNotReplaceTheCurrentDetail() throws {
        let rig = makeRig(seed: { seedTodos($0) })
        rig.surface.select(.todos)
        XCTAssertTrue(waitUntil { rig.surface.rowTexts.count == 2 })
        rig.log.frames.removeAll()

        rig.surface.selectItem(id: "todo:2")
        rig.surface.selectItem(id: "todo:1")
        let requests = rig.log.detailRequests
        let first = try XCTUnwrap(requests.first { $0.itemId == "todo:2" })
        let second = try XCTUnwrap(requests.last { $0.itemId == "todo:1" })

        rig.store.resolve(requestId: first.requestId,
                          with: .detail(.ok(WorkTestSupport.makeDetail(itemId: "todo:2", title: "Detail of two"))))
        settle()
        XCTAssertNotEqual(rig.surface.detailTitle, "Detail of two", "the user has moved on to todo:1")

        rig.store.resolve(requestId: second.requestId,
                          with: .detail(.ok(WorkTestSupport.makeDetail(itemId: "todo:1", title: "Detail of one"))))
        XCTAssertTrue(waitUntil { rig.surface.detailTitle == "Detail of one" })
        XCTAssertEqual(rig.surface.selectedItemId, "todo:1")
    }

    // MARK: View state

    func testSelectedTabSearchAndSelectionAreRestoredFromDefaults() {
        let defaults = makeDefaults()
        var saved = TeriViewState()
        saved.selectedTab = .todos
        saved[.todos].filter.query = "payment"
        saved[.todos].selectedItemId = "todo:2"
        saved.save(to: defaults)

        let rig = makeRig(defaults: defaults, seed: { seedTodos($0) })

        XCTAssertEqual(rig.surface.selectedTab, .todos)
        XCTAssertEqual(rig.surface.selectedItemId, "todo:2")
        XCTAssertTrue(waitUntil { rig.surface.rowTexts.count == 1 },
                      "the restored search narrows the list: \(titles(rig.surface.rowTexts))")
        XCTAssertEqual(titles(rig.surface.rowTexts), ["Fix payment webhook"])
    }

    func testAnotherTabCanBeTheRestoredOne() {
        let defaults = makeDefaults()
        var saved = TeriViewState()
        saved.selectedTab = .sentry
        saved.save(to: defaults)

        XCTAssertEqual(makeRig(defaults: defaults).surface.selectedTab, .sentry)
    }

    func testChangingTabAndSelectionIsPersistedAndRestoredByTheNextSurface() {
        let defaults = makeDefaults()
        let rig = makeRig(defaults: defaults, seed: { seedTodos($0) })

        rig.surface.select(.todos)
        XCTAssertTrue(waitUntil { rig.surface.rowTexts.count == 2 })
        rig.surface.selectItem(id: "todo:1")
        rig.surface.select(.jira)

        XCTAssertTrue(waitUntil(8) {
            let s = TeriViewState.load(from: defaults)
            return s.selectedTab == .jira && s[.todos].selectedItemId == "todo:1"
        }, "view state never reached UserDefaults: \(TeriViewState.load(from: defaults))")

        let next = makeRig(defaults: defaults, seed: { seedTodos($0) })
        XCTAssertEqual(next.surface.selectedTab, .jira)
        next.surface.select(.todos)
        XCTAssertEqual(next.surface.selectedItemId, "todo:1", "each tab remembers its own selection")
    }

    // MARK: Deep links

    func testADeepLinkSelectsTheNamedTab() {
        let rig = makeRig()
        rig.surface.select(.todos)

        FocusDeepLink.post(.teriTab("jira"), center: rig.center)
        XCTAssertTrue(waitUntil { rig.surface.selectedTab == .jira })

        FocusDeepLink.post(.teriTab("repo_docs"), center: rig.center)
        XCTAssertTrue(waitUntil { rig.surface.selectedTab == .repoDocs })
    }

    func testDeepLinksForOtherSurfacesOrUnknownTabsAreIgnored() {
        let rig = makeRig()
        rig.surface.select(.sentry)

        FocusDeepLink.post(.teriTab("no_such_tab"), center: rig.center)
        FocusDeepLink.post(.fredInbox, center: rig.center)
        settle()

        XCTAssertEqual(rig.surface.selectedTab, .sentry)
    }

    func testADeepLinkOnAnotherCenterDoesNotReachThisSurface() {
        let rig = makeRig()
        rig.surface.select(.sentry)
        FocusDeepLink.post(.teriTab("jira"), center: NotificationCenter())
        settle()
        XCTAssertEqual(rig.surface.selectedTab, .sentry)
    }

    // MARK: Disconnected

    func testLosingTheDaemonDimsEveryTabKeepsTheDataAndShowsOneBanner() {
        let rig = makeRig(seed: { seedTodos($0) })
        rig.surface.select(.todos)
        XCTAssertTrue(waitUntil { rig.surface.rowTexts.count == 2 })
        XCTAssertFalse(rig.surface.isDisconnectedBannerVisible)
        XCTAssertFalse(rig.surface.allTabsDimmed)

        rig.store.setConnected(false)

        XCTAssertTrue(waitUntil { rig.surface.isDisconnectedBannerVisible })
        XCTAssertTrue(rig.surface.allTabsDimmed)
        XCTAssertEqual(rig.surface.rowTexts.count, 2, "what was on screen stays on screen")
        XCTAssertEqual(rig.surface.tabButtonTitle(.todos), "Todos 2")

        rig.store.setConnected(true)

        XCTAssertTrue(waitUntil { !rig.surface.isDisconnectedBannerVisible })
        XCTAssertFalse(rig.surface.allTabsDimmed)
    }

    // MARK: Keyboard

    private func focusInside(_ rig: Rig) {
        let child = FocusableView()
        rig.surface.addSubview(child)
        XCTAssertTrue(rig.window.makeFirstResponder(child), "precondition: focus is inside the surface")
    }

    private let digitKeys: [(chars: String, code: UInt16, tab: TeriTab)] = [
        ("1", 18, .picks), ("2", 19, .todos), ("3", 20, .jira), ("4", 21, .sentry), ("5", 23, .repoDocs),
    ]

    func testCommandOneThroughFiveSwitchTabsWhileTheSurfaceHasFocus() {
        let rig = makeRig()
        focusInside(rig)
        rig.surface.select(.repoDocs)
        rig.surface.select(.sentry)   // so the first key changes the tab

        for key in digitKeys {
            let handled = rig.surface.performKeyEquivalent(with: keyEvent(key.chars, code: key.code, window: rig.window))
            XCTAssertTrue(handled, "cmd-\(key.chars) should be handled")
            XCTAssertEqual(rig.surface.selectedTab, key.tab, "cmd-\(key.chars)")
        }
    }

    func testCommandTwoSwitchesToTodosFromARestoredOtherTab() {
        let defaults = makeDefaults()
        var saved = TeriViewState()
        saved.selectedTab = .sentry
        saved.save(to: defaults)
        let rig = makeRig(defaults: defaults)
        focusInside(rig)
        XCTAssertEqual(rig.surface.selectedTab, .sentry)

        XCTAssertTrue(rig.surface.performKeyEquivalent(with: keyEvent("2", code: 19, window: rig.window)))

        XCTAssertEqual(rig.surface.selectedTab, .todos)
    }

    func testOtherKeysAreNotSwallowed() {
        let rig = makeRig()
        focusInside(rig)
        rig.surface.select(.sentry)

        XCTAssertFalse(rig.surface.performKeyEquivalent(with: keyEvent("2", code: 19, window: rig.window, flags: [])),
                       "a bare digit is typing, not a shortcut")
        XCTAssertFalse(rig.surface.performKeyEquivalent(with: keyEvent("6", code: 22, window: rig.window)),
                       "there is no sixth tab")
        XCTAssertFalse(rig.surface.performKeyEquivalent(with: keyEvent("2", code: 19, window: rig.window, flags: [.command, .shift])),
                       "cmd-shift-2 belongs to someone else")
        XCTAssertEqual(rig.surface.selectedTab, .sentry)
    }

    func testTheShortcutsAreIgnoredWhenFocusIsElsewhereInTheWindow() {
        let rig = makeRig()
        let elsewhere = FocusableView()
        rig.window.contentView!.addSubview(elsewhere)   // sibling of the surface, not inside it
        XCTAssertTrue(rig.window.makeFirstResponder(elsewhere))
        rig.surface.select(.sentry)

        XCTAssertFalse(rig.surface.performKeyEquivalent(with: keyEvent("2", code: 19, window: rig.window)))
        XCTAssertEqual(rig.surface.selectedTab, .sentry, "cmd-2 must not steal the key from another focus")
    }

    func testTheShortcutsAreIgnoredInAWindowThatIsNotKey() {
        let store = WorkStore()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        addTeardownBlock { window.close() }
        let surface = TeriSurfaceView(store: store, defaults: makeDefaults(), center: NotificationCenter())
        surface.frame = window.contentView!.bounds
        window.contentView!.addSubview(surface)
        let child = FocusableView()
        surface.addSubview(child)
        XCTAssertTrue(window.makeFirstResponder(child))
        XCTAssertFalse(window.isKeyWindow, "precondition: this window was never made key")
        surface.select(.sentry)

        XCTAssertFalse(surface.performKeyEquivalent(with: keyEvent("2", code: 19, window: window)))
        XCTAssertEqual(surface.selectedTab, .sentry)
    }

    func testCommandRRefreshesTheSelectedTabsSource() {
        let rig = makeRig()
        focusInside(rig)
        rig.surface.select(.jira)
        rig.log.frames.removeAll()

        XCTAssertTrue(rig.surface.performKeyEquivalent(with: keyEvent("r", code: 15, window: rig.window)))

        XCTAssertEqual(rig.log.frames, [.refresh(source: .jira, fred: false)])

        rig.surface.select(.todos)
        rig.log.frames.removeAll()
        XCTAssertTrue(rig.surface.performKeyEquivalent(with: keyEvent("r", code: 15, window: rig.window)))
        XCTAssertEqual(rig.log.frames, [.refresh(source: .todos, fred: false)])
    }
}

// MARK: - Detail links (security edge cases)

/// Work item text is untrusted (a Jira description, a doc in a repo). Only web
/// links may ever be launched from the detail pane.
final class WorkDetailViewLinkSafetyTests: XCTestCase {
    private func detail(links: [(String, String)]) throws -> WorkItemDetail {
        let json: [String: Any] = [
            "item_id": "jira:X-1", "title": "T", "markdown": "[a](file:///Applications/Calculator.app)",
            "links": links.map { ["label": $0.0, "url": $0.1] },
        ]
        return try JSONDecoder().decode(WorkItemDetail.self, from: try JSONSerialization.data(withJSONObject: json))
    }

    func testOnlyWebLinksBecomeOpenTargets() throws {
        let d = try detail(links: [
            ("file", "file:///Applications/Calculator.app"), ("ssh", "ssh://host"), ("js", "javascript:alert(1)"),
            ("mail", "mailto:a@b.c"), ("ok", "https://example.com/browse/X-1"), ("plain http", "HTTP://example.com"),
        ])
        let targets = WorkDetailView.targets(for: .detail(d), item: nil)
        XCTAssertEqual(targets.map(\.label), ["ok", "plain http"])
    }

    func testAnItemUrlThatIsNotWebIsNotAnOpenTarget() {
        let item = WorkTestSupport.makeItem(["id": "jira:X-1", "source": "jira", "kind": "task", "title": "t",
                                             "url": "file:///etc/passwd"])
        XCTAssertTrue(WorkDetailView.targets(for: .none, item: item).isEmpty)
    }

    func testClickingALinkInTheBodyOpensWebLinksOnlyAndNeverFallsThrough() {
        let view = WorkDetailView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        var opened: [URL] = []
        view.opener = { if case .url(_, let url) = $0 { opened.append(url) } }
        let text = NSTextView()

        XCTAssertTrue(view.textView(text, clickedOnLink: URL(string: "file:///Applications/Calculator.app")!, at: 0))
        XCTAssertTrue(view.textView(text, clickedOnLink: "x-apple.systempreferences:", at: 0))
        XCTAssertTrue(view.textView(text, clickedOnLink: URL(string: "https://example.com/a")!, at: 0))

        XCTAssertEqual(opened, [URL(string: "https://example.com/a")!], "only the web link was opened")
    }
}
