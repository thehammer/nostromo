import XCTest
import AppKit

// PR #221 review fix-ups: the Teri view state is never lost (a pending save is
// flushed when the store goes away or the app quits) and two Teri windows
// sharing one UserDefaults do not overwrite each other's changes. Nothing here
// sleeps: the debounce is driven by `ManualScheduler`.

// MARK: - Test double

/// A `WorkScheduler` that never runs anything by itself. It records what was
/// scheduled (and with which delay), honours cancellation, and runs the pending
/// work when the test says so.
final class ManualScheduler {
    private final class Entry {
        let delay: TimeInterval
        let work: () -> Void
        var isCancelled = false
        var hasRun = false
        init(delay: TimeInterval, work: @escaping () -> Void) { self.delay = delay; self.work = work }
        var isPending: Bool { !isCancelled && !hasRun }
    }

    private var entries: [Entry] = []

    /// The value to inject.
    var scheduler: WorkScheduler {
        WorkScheduler { [self] delay, work in
            let entry = Entry(delay: delay, work: work)
            entries.append(entry)
            return { entry.isCancelled = true }
        }
    }

    /// Scheduled work that has neither run nor been cancelled.
    var pendingCount: Int { entries.filter(\.isPending).count }

    /// Delays of the pending work, in scheduling order.
    var pendingDelays: [TimeInterval] { entries.filter(\.isPending).map(\.delay) }

    /// Everything ever scheduled, cancelled or not.
    var scheduledCount: Int { entries.count }

    /// Runs, in order, everything that is pending right now.
    func fireAll() {
        for entry in entries where entry.isPending {
            entry.hasRun = true
            entry.work()
        }
    }
}

// MARK: - Store

final class TeriViewStateStoreTests: XCTestCase {
    private var suites: [String] = []

    private func makeDefaults() -> UserDefaults {
        let name = "nostromo.tests.teriViewStateStore.\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    override func tearDown() {
        for name in suites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        suites.removeAll()
        super.tearDown()
    }

    private func makeStore(_ defaults: UserDefaults, _ manual: ManualScheduler,
                           center: NotificationCenter = NotificationCenter()) -> TeriViewStateStore {
        TeriViewStateStore(defaults: defaults, scheduler: manual.scheduler, center: center)
    }

    // MARK: Debounce

    func testAnUpdateSchedulesOneSaveAtTheDebounceDelayAndWritesNothingUntilItRuns() {
        let defaults = makeDefaults()
        let manual = ManualScheduler()
        let store = makeStore(defaults, manual)

        store.update { $0.selectedTab = .jira }

        XCTAssertEqual(manual.pendingCount, 1, "one save is scheduled")
        XCTAssertEqual(manual.pendingDelays, [0.5], "at the default 0.5 s debounce")
        XCTAssertNil(defaults.data(forKey: TeriViewState.defaultsKey), "nothing is written before the scheduler runs")

        manual.fireAll()

        XCTAssertEqual(TeriViewState.load(from: defaults).selectedTab, .jira)
    }

    func testRepeatedUpdatesReplaceThePendingSaveInsteadOfStackingThem() {
        let defaults = makeDefaults()
        let manual = ManualScheduler()
        let store = makeStore(defaults, manual)

        store.update { $0.selectedTab = .jira }
        store.update { $0[.jira].filter.query = "crash" }
        store.update { $0[.jira].selectedItemId = "jira:CORE-1" }

        XCTAssertEqual(manual.pendingCount, 1, "each update cancels the previous pending save")
        XCTAssertNil(defaults.data(forKey: TeriViewState.defaultsKey))

        manual.fireAll()

        let loaded = TeriViewState.load(from: defaults)
        XCTAssertEqual(loaded.selectedTab, .jira)
        XCTAssertEqual(loaded[.jira].filter.query, "crash")
        XCTAssertEqual(loaded[.jira].selectedItemId, "jira:CORE-1", "the one save carries every update")
    }

    func testFlushWritesAtOnceAndCancelsThePendingSave() {
        let defaults = makeDefaults()
        let manual = ManualScheduler()
        let store = makeStore(defaults, manual)
        store.update { $0.selectedTab = .sentry }

        store.flush()

        XCTAssertEqual(TeriViewState.load(from: defaults).selectedTab, .sentry, "written now")
        XCTAssertEqual(manual.pendingCount, 0, "the scheduled save was cancelled")

        defaults.removeObject(forKey: TeriViewState.defaultsKey)
        manual.fireAll()
        XCTAssertNil(defaults.data(forKey: TeriViewState.defaultsKey), "a cancelled save never runs")
    }

    // MARK: Never lost

    func testDeallocatingTheStoreFlushesAPendingUpdate() {
        let defaults = makeDefaults()
        let manual = ManualScheduler()

        autoreleasepool {
            let store = makeStore(defaults, manual)
            store.update { $0.selectedTab = .jira; $0[.jira].selectedItemId = "jira:CORE-1" }
            XCTAssertNil(defaults.data(forKey: TeriViewState.defaultsKey), "precondition: still pending")
        }

        let loaded = TeriViewState.load(from: defaults)
        XCTAssertEqual(loaded.selectedTab, .jira, "the last change was lost when the store went away")
        XCTAssertEqual(loaded[.jira].selectedItemId, "jira:CORE-1")
    }

    func testTheAppTerminatingFlushesAPendingUpdate() {
        let defaults = makeDefaults()
        let manual = ManualScheduler()
        let center = NotificationCenter()
        let store = makeStore(defaults, manual, center: center)
        store.update { $0.selectedTab = .repoDocs }
        XCTAssertNil(defaults.data(forKey: TeriViewState.defaultsKey), "precondition: still pending")

        center.post(name: NSApplication.willTerminateNotification, object: NSApplication.shared)

        XCTAssertEqual(TeriViewState.load(from: defaults).selectedTab, .repoDocs)
        withExtendedLifetime(store) {}
    }

    // MARK: Two windows, one defaults

    func testTwoWindowsChangingDifferentThingsBothSurviveWhicheverFlushesLast() {
        for aFirst in [true, false] {
            let defaults = makeDefaults()
            let manual = ManualScheduler()
            let windowA = makeStore(defaults, manual)
            let windowB = makeStore(defaults, manual)

            windowA.update { $0.selectedTab = .jira }
            windowB.update { $0[.todos].selectedItemId = "todo:7" }
            if aFirst { windowA.flush(); windowB.flush() } else { windowB.flush(); windowA.flush() }

            let loaded = TeriViewState.load(from: defaults)
            XCTAssertEqual(loaded.selectedTab, .jira, "window A's tab was overwritten (A first: \(aFirst))")
            XCTAssertEqual(loaded[.todos].selectedItemId, "todo:7", "window B's selection was overwritten (A first: \(aFirst))")
        }
    }

    func testDifferentTabsAndTheSplitFractionAreMergedPerKey() {
        let defaults = makeDefaults()
        let manual = ManualScheduler()
        let windowA = makeStore(defaults, manual)
        let windowB = makeStore(defaults, manual)
        let windowC = makeStore(defaults, manual)

        windowA.update { $0[.todos].filter.query = "payment" }
        windowB.update { $0[.sentry].sort = .oldest }
        windowC.update { $0.splitFraction = 0.35 }
        windowB.flush(); windowC.flush(); windowA.flush()

        let loaded = TeriViewState.load(from: defaults)
        XCTAssertEqual(loaded[.todos].filter.query, "payment")
        XCTAssertEqual(loaded[.sentry].sort, .oldest)
        XCTAssertEqual(loaded.splitFraction ?? -1, 0.35, accuracy: 0.0001)
    }

    func testAWindowThatNeverChangedAKeyDoesNotOverwriteAnotherWindowsChangeToIt() {
        let defaults = makeDefaults()
        var seeded = TeriViewState()
        seeded.selectedTab = .todos
        seeded[.todos].selectedItemId = "todo:1"
        seeded.splitFraction = 0.3
        seeded.save(to: defaults)
        let manual = ManualScheduler()
        let windowA = makeStore(defaults, manual)   // both start from the seeded state
        let windowB = makeStore(defaults, manual)

        windowA.update { $0[.todos].selectedItemId = "todo:2"; $0.splitFraction = 0.5 }
        windowA.flush()
        windowB.update { $0.selectedTab = .sentry }   // B only ever touched the tab
        windowB.flush()

        let loaded = TeriViewState.load(from: defaults)
        XCTAssertEqual(loaded.selectedTab, .sentry)
        XCTAssertEqual(loaded[.todos].selectedItemId, "todo:2", "B must not write back its stale copy of the selection")
        XCTAssertEqual(loaded.splitFraction ?? -1, 0.5, accuracy: 0.0001, "nor its stale split fraction")
    }

    func testWhenTwoWindowsChangeTheSameKeyTheLastFlushWins() {
        let defaults = makeDefaults()
        let manual = ManualScheduler()
        let windowA = makeStore(defaults, manual)
        let windowB = makeStore(defaults, manual)

        windowA.update { $0.selectedTab = .jira }
        windowB.update { $0.selectedTab = .sentry }
        windowA.flush()
        windowB.flush()

        XCTAssertEqual(TeriViewState.load(from: defaults).selectedTab, .sentry)
    }
}

// MARK: - Split fraction in the persisted state

final class TeriViewStateSplitFractionTests: XCTestCase {
    private var suites: [String] = []

    private func makeDefaults() -> UserDefaults {
        let name = "nostromo.tests.teriViewStateSplit.\(UUID().uuidString)"
        suites.append(name)
        return UserDefaults(suiteName: name)!
    }

    override func tearDown() {
        for name in suites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        suites.removeAll()
        super.tearDown()
    }

    func testTheSplitFractionRoundTripsInsideTheExistingStateKey() throws {
        let defaults = makeDefaults()
        var state = TeriViewState()
        state.selectedTab = .todos
        state.splitFraction = 0.4
        state.save(to: defaults)

        let loaded = TeriViewState.load(from: defaults)
        XCTAssertEqual(loaded.splitFraction ?? -1, 0.4, accuracy: 0.0001)
        XCTAssertEqual(loaded, state)
        let data = try XCTUnwrap(defaults.data(forKey: TeriViewState.defaultsKey))
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(obj["splitFraction"], "stored in the same JSON as the rest of the view state")
    }

    func testStateSavedBeforeTheSplitFractionExistedStillLoads() throws {
        let defaults = makeDefaults()
        let old = #"{"selectedTab": "jira", "tabs": {"todos": {"selectedItemId": "todo:3"}}}"#
        defaults.set(Data(old.utf8), forKey: TeriViewState.defaultsKey)

        let loaded = TeriViewState.load(from: defaults)

        XCTAssertNil(loaded.splitFraction)
        XCTAssertEqual(loaded.selectedTab, .jira)
        XCTAssertEqual(loaded[.todos].selectedItemId, "todo:3")
    }

    func testAnUnsetSplitFractionStaysUnset() {
        let defaults = makeDefaults()
        TeriViewState().save(to: defaults)
        XCTAssertNil(TeriViewState.load(from: defaults).splitFraction)
    }
}
