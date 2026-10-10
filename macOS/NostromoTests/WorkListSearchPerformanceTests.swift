import XCTest
import AppKit

// PR #221 review fix-ups: typing in the Teri list's search box must stay cheap.
// A burst of keystrokes is one filter pass (debounced), re-applying data that
// did not change rebuilds nothing, and the date formatters behind the todo rows
// are shared. Nothing here sleeps or measures time: the debounce is driven by
// `ManualScheduler` and "cheap" is counted in calls.

private final class RowCalls {
    var itemIds: [String] = []
}

private final class FilterLog {
    var calls: [(filter: WorkFilter, sort: WorkSortKey)] = []
}

private func makeConfig(_ calls: RowCalls) -> WorkListConfig {
    WorkListConfig(
        rowContent: { item in
            calls.itemIds.append(item.id)
            return WorkRowContent(title: item.title, accessibilityLabel: item.title)
        },
        chipFacet: .status,
        menuFacets: [.kind],
        sortOptions: [("Newest", .newest), ("Title", .title)],
        searchPlaceholder: "Filter todos")
}

private func flatSnapshot(_ items: [WorkItem], statusCounts: [String: Int] = ["open": 2],
                          kindCounts: [String: Int] = ["todo": 2]) -> WorkListSnapshot {
    WorkListSnapshot(groups: [WorkGroup(key: nil, items: items)],
                     totalCount: items.count, filteredCount: items.count,
                     facetCounts: [.status: statusCounts, .kind: kindCounts])
}

private func allViews(_ root: NSView) -> [NSView] { rigAllSubviews(of: root) }

// MARK: - Search debounce

final class WorkListSearchDebounceTests: XCTestCase {
    private let manual = ManualScheduler()
    private let log = FilterLog()
    private let rows = RowCalls()
    private var list: WorkListView!

    override func setUp() {
        super.setUp()
        list = WorkListView(config: makeConfig(rows), scheduler: manual.scheduler)
        list.onFilterChange = { [log] filter, sort in log.calls.append((filter, sort)) }
        list.apply(snapshot: flatSnapshot([WorkTestSupport.todo(1, "Alpha"), WorkTestSupport.todo(2, "Beta")]),
                   isLoading: false, placeholder: nil)
    }

    private var searchField: NSSearchField {
        allViews(list).compactMap { $0 as? NSSearchField }.first!
    }

    private func type(_ text: String) {
        let field = searchField
        field.stringValue = text
        field.sendAction(field.action, to: field.target)
    }

    func testTypingDoesNotFilterUntilTheDebounceRuns() {
        type("pay")

        XCTAssertEqual(log.calls.count, 0, "the filter must not run on the keystroke itself")
        XCTAssertEqual(manual.pendingCount, 1, "one debounced filter is scheduled")
        let delay = manual.pendingDelays.first ?? -1
        XCTAssertTrue((0.1...0.15).contains(delay), "debounce delay was \(delay)")

        manual.fireAll()

        XCTAssertEqual(log.calls.count, 1)
        XCTAssertEqual(log.calls.first?.filter.query, "pay")
    }

    func testABurstOfKeystrokesIsOneFilterPassWithTheLastText() {
        type("p")
        type("pa")
        type("pay")

        XCTAssertEqual(log.calls.count, 0)
        manual.fireAll()

        XCTAssertEqual(log.calls.map(\.filter.query), ["pay"],
                       "exactly one callback, carrying the last text and never a stale one")
    }

    func testKeystrokesAfterAFilterPassStartANewDebounce() {
        type("pay")
        manual.fireAll()
        type("payment")

        XCTAssertEqual(log.calls.map(\.filter.query), ["pay"], "the second burst has not run yet")
        manual.fireAll()
        XCTAssertEqual(log.calls.map(\.filter.query), ["pay", "payment"])
    }

    func testChipSortAndMenuChangesAreNotDebounced() throws {
        // A chip.
        let chip = try XCTUnwrap(allViews(list).compactMap { $0 as? NSButton }.first { $0.title.hasPrefix("open") })
        chip.sendAction(chip.action, to: chip.target)
        XCTAssertEqual(log.calls.count, 1, "chip toggles apply at once")
        XCTAssertEqual(log.calls.last?.filter.statuses, ["open"])

        // The sort popup.
        let sortPopup = try XCTUnwrap(allViews(list).compactMap { $0 as? NSPopUpButton }.first { !$0.pullsDown })
        sortPopup.selectItem(at: 1)
        sortPopup.sendAction(sortPopup.action, to: sortPopup.target)
        XCTAssertEqual(log.calls.count, 2, "sort changes apply at once")
        XCTAssertEqual(log.calls.last?.sort, .title)

        // A menu facet value.
        let menu = try XCTUnwrap(allViews(list).compactMap { $0 as? NSPopUpButton }.first { $0.pullsDown })
        let value = try XCTUnwrap(menu.menu?.items.first { $0.title.hasPrefix("todo") })
        NSApplication.shared.sendAction(try XCTUnwrap(value.action), to: value.target, from: value)
        XCTAssertEqual(log.calls.count, 3, "menu choices apply at once")
        XCTAssertEqual(log.calls.last?.filter.kinds, ["todo"])

        XCTAssertEqual(manual.pendingCount, 0, "none of them went through the debounce")
    }
}

// MARK: - No needless rebuilds

final class WorkListRebuildTests: XCTestCase {
    private let rows = RowCalls()
    private var list: WorkListView!
    private var selections: [String?] = []

    override func setUp() {
        super.setUp()
        list = WorkListView(config: makeConfig(rows), scheduler: ManualScheduler().scheduler)
        list.onSelectionChange = { [unowned self] in self.selections.append($0?.id) }
    }

    private let one = WorkTestSupport.todo(1, "Alpha")
    private let two = WorkTestSupport.todo(2, "Beta")

    private func apply(_ snapshot: WorkListSnapshot) {
        list.apply(snapshot: snapshot, isLoading: false, placeholder: nil)
    }

    func testApplyingTheSameSnapshotTwiceRebuildsNothing() {
        let snapshot = flatSnapshot([one, two])
        apply(snapshot)
        let rowsBefore = list.visibleRows
        let rebuilds = list.filterControlRebuildCount
        rows.itemIds.removeAll()

        apply(snapshot)

        XCTAssertEqual(rows.itemIds, [], "no row content is recomputed for unchanged items")
        XCTAssertEqual(list.visibleRows, rowsBefore)
        XCTAssertEqual(list.filterControlRebuildCount, rebuilds, "chips and menus are not rebuilt for unchanged counts")
    }

    func testTheSelectedRowSurvivesAnUnchangedReapply() {
        let snapshot = flatSnapshot([one, two])
        apply(snapshot)
        list.select(itemId: "todo:2")
        selections.removeAll()

        apply(snapshot)

        XCTAssertEqual(list.selectedItem?.id, "todo:2")
        XCTAssertEqual(selections, [], "re-applying is not a user selection")
    }

    func testChangingOneItemRecomputesOnlyThatRow() {
        apply(flatSnapshot([one, two]))
        list.select(itemId: "todo:2")
        let rebuilds = list.filterControlRebuildCount
        rows.itemIds.removeAll()

        apply(flatSnapshot([WorkTestSupport.todo(1, "Alpha, renamed"), two]))

        XCTAssertEqual(rows.itemIds, ["todo:1"], "only the changed item's row content is recomputed")
        XCTAssertEqual(list.visibleRows.map(\.title), ["Alpha, renamed", "Beta"])
        XCTAssertEqual(list.filterControlRebuildCount, rebuilds, "the facet counts did not change")
        XCTAssertEqual(list.selectedItem?.id, "todo:2", "the selection stays")
    }

    func testAddingAnItemRecomputesOnlyTheNewRow() {
        apply(flatSnapshot([one, two]))
        rows.itemIds.removeAll()

        apply(flatSnapshot([one, two, WorkTestSupport.todo(3, "Gamma")]))

        XCTAssertEqual(rows.itemIds, ["todo:3"])
        XCTAssertEqual(list.visibleRows.map(\.title), ["Alpha", "Beta", "Gamma"])
    }

    func testChangedFacetCountsRebuildTheChipsAndShowTheNewCount() {
        apply(flatSnapshot([one, two], statusCounts: ["open": 2]))
        func chipTitles() -> [String] {
            allViews(list).compactMap { $0 as? NSButton }.map(\.title).filter { $0.hasPrefix("open") }
        }
        XCTAssertEqual(chipTitles(), ["open 2"], "precondition")
        let rebuilds = list.filterControlRebuildCount
        rows.itemIds.removeAll()

        apply(flatSnapshot([one, two], statusCounts: ["open": 3]))

        XCTAssertGreaterThan(list.filterControlRebuildCount, rebuilds, "new counts need new chips")
        XCTAssertEqual(chipTitles(), ["open 3"])
        XCTAssertEqual(rows.itemIds, [], "the rows themselves did not change")
    }
}

// MARK: - Shared date formatters

final class TeriDateFormatterReuseTests: XCTestCase {
    private func calendar(_ zone: String, locale: String = "en_US_POSIX") -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: zone)!
        c.locale = Locale(identifier: locale)
        return c
    }

    /// Friday 9 October 2026, mid-afternoon UTC.
    private let now = ISO8601DateFormatter().date(from: "2026-10-09T15:00:00Z")!

    func testBuildingManyRowsReusesTheDateFormatters() {
        let utc = calendar("UTC")
        let soon = WorkTestSupport.todo(1, "t", due: "2026-10-12")      // "Due Mon"
        let later = WorkTestSupport.todo(2, "t", due: "2026-10-29")     // "Due Oct 29"
        let before = TeriDateFormatters.createdCount

        var texts = Set<String>()
        for _ in 0..<250 {
            texts.insert(TeriTodosTab.rowContent(for: soon, now: now, calendar: utc).dueText ?? "nil")
            texts.insert(TeriTodosTab.rowContent(for: later, now: now, calendar: utc).dueText ?? "nil")
        }

        XCTAssertEqual(texts, ["Due Mon", "Due Oct 29"])
        let created = TeriDateFormatters.createdCount - before
        XCTAssertLessThanOrEqual(created, 2, "500 rows created \(created) date formatters (one per pattern is enough)")
    }

    func testAskingForTheSameFormatTwiceDoesNotBuildAnotherFormatter() {
        let utc = calendar("UTC")
        _ = TeriDateFormatters.string(from: now, pattern: "EEE", calendar: utc)   // warm
        let before = TeriDateFormatters.createdCount

        for _ in 0..<100 { _ = TeriDateFormatters.string(from: now, pattern: "EEE", calendar: utc) }

        XCTAssertEqual(TeriDateFormatters.createdCount, before)
    }

    func testTheSameInstantFormatsPerCalendarTimeZoneEvenWhenFormattersAreShared() {
        let lateFridayUTC = ISO8601DateFormatter().date(from: "2026-10-09T23:30:00Z")!   // Saturday 08:30 in Tokyo
        let utc = calendar("UTC")
        let tokyo = calendar("Asia/Tokyo")

        XCTAssertEqual(TeriDateFormatters.string(from: lateFridayUTC, pattern: "EEE", calendar: utc), "Fri")
        XCTAssertEqual(TeriDateFormatters.string(from: lateFridayUTC, pattern: "EEE", calendar: tokyo), "Sat")
        XCTAssertEqual(TeriDateFormatters.string(from: lateFridayUTC, pattern: "MMM d", calendar: utc), "Oct 9")
        XCTAssertEqual(TeriDateFormatters.string(from: lateFridayUTC, pattern: "MMM d", calendar: tokyo), "Oct 10")
        XCTAssertEqual(TeriDateFormatters.string(from: lateFridayUTC, pattern: "EEE", calendar: utc), "Fri",
                       "going back to the first calendar still gives its own answer")
    }

    func testTheCalendarsLocaleDecidesTheLanguage() {
        let english = TeriDateFormatters.string(from: now, pattern: "EEE", calendar: calendar("UTC"))
        let german = TeriDateFormatters.string(from: now, pattern: "EEE", calendar: calendar("UTC", locale: "de_DE"))

        XCTAssertEqual(english, "Fri")
        XCTAssertNotEqual(german, english, "a German calendar must not get the cached English weekday")
    }
}
