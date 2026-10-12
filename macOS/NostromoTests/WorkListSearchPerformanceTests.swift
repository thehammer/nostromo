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

// MARK: - A selected row stays readable (generic list rows)
//
// Contract for `WorkListView`'s row text on the two selection fills AppKit paints:
//
//  - Row selected in the key window (cell `backgroundStyle == .emphasized`): the fill is the
//    system selection colour (`selectedContentBackgroundColor`, a saturated blue by default).
//    EVERY text (priority, kind, title, due, status, urgent or not) is white. White is the
//    lightest colour there is, so it is the best the platform allows: on the default blue it
//    measures 5.4-6.3:1, above the 4.5:1 body-text bar. The contrast bar is asserted against a
//    fixed stand-in for that blue (the real fill follows the Mac's accent colour, which a test
//    must not depend on); on other accents white is still the colour, by design.
//  - Row selected but its window not active (`backgroundStyle != .emphasized`, the row view
//    still `isSelected`): the fill is `unemphasizedSelectedContentBackgroundColor`, a grey that
//    flips between light and dark with the appearance. Every text reaches 4.5:1 on it, in both
//    appearances (so the colours are adaptive, not the dark-surface ones).
//  - An unselected row keeps its dark-surface colours, and a row leaving the selection gets them back.
//
// The real list builds the cells; the tests then put the row in each state the way AppKit does
// (select the row, then hand the cell its background style again). System colours are resolved
// under the cell's own effective appearance, never hard-coded.

private struct SelColor { var r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat }

private func selResolve(_ color: NSColor, in appearance: NSAppearance) -> SelColor? {
    var out: SelColor?
    appearance.performAsCurrentDrawingAppearance {
        guard let c = color.usingColorSpace(.sRGB) else { return }
        out = SelColor(r: c.redComponent, g: c.greenComponent, b: c.blueComponent, a: c.alphaComponent)
    }
    return out
}

private func selOver(_ top: SelColor, _ back: SelColor) -> SelColor {
    SelColor(r: top.r * top.a + back.r * (1 - top.a), g: top.g * top.a + back.g * (1 - top.a),
             b: top.b * top.a + back.b * (1 - top.a), a: 1)
}

private func selLuminance(_ c: SelColor) -> CGFloat {
    func lin(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
}

/// WCAG contrast ratio of `text` on the opaque `fill`.
private func selContrast(_ text: SelColor, on fill: SelColor) -> CGFloat {
    let l1 = selLuminance(selOver(text, fill)), l2 = selLuminance(fill)
    return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
}

private func selClose(_ a: SelColor, _ b: SelColor) -> Bool {
    abs(a.r - b.r) < 0.01 && abs(a.g - b.g) < 0.01 && abs(a.b - b.b) < 0.01
}

private func selDescribe(_ c: SelColor) -> String { String(format: "rgb(%.2f, %.2f, %.2f)", c.r, c.g, c.b) }

final class WorkRowSelectionContrastTests: XCTestCase {
    private let appearances: [(name: String, appearance: NSAppearance)] = [
        ("darkAqua", NSAppearance(named: .darkAqua)!),
        ("aqua", NSAppearance(named: .aqua)!),
    ]

    /// Four rows covering every colour the row draws: P1 + urgent due, P2, P3, P5.
    private let items = [
        WorkTestSupport.todo(1, "Urgent first", priority: 1),
        WorkTestSupport.todo(2, "Second", priority: 2),
        WorkTestSupport.todo(3, "Third", priority: 3),
        WorkTestSupport.todo(4, "Fifth", priority: 5),
    ]

    private enum Part: String, CaseIterable { case priority, kind, title, due, status }

    private struct Rig {
        let window: RigWindow
        let outline: NSOutlineView
    }

    private func makeRig(_ appearance: NSAppearance) throws -> Rig {
        let window = makeRigWindow(self, appearance: appearance)
        let config = WorkListConfig(
            rowContent: { item in
                WorkRowContent(priorityText: item.priority?.label, priorityRank: item.priority?.rank,
                               kindText: "✖ Bug", title: item.title, dueText: "Due today",
                               dueIsUrgent: item.title.hasPrefix("Urgent"), statusText: "open",
                               accessibilityLabel: item.title)
            },
            sortOptions: [])
        let list = WorkListView(config: config, scheduler: ManualScheduler().scheduler)
        list.frame = NSRect(x: 0, y: 0, width: 700, height: 300)
        window.contentView!.addSubview(list)
        list.apply(snapshot: flatSnapshot(items), isLoading: false, placeholder: nil)
        list.layoutSubtreeIfNeeded()
        rigSettle()
        let outline = try XCTUnwrap(allViews(list).compactMap { $0 as? NSOutlineView }.first)
        return Rig(window: window, outline: outline)
    }

    private func fields(_ cell: NSTableCellView, _ item: WorkItem) throws -> [Part: NSTextField] {
        let texts = allViews(cell).compactMap { $0 as? NSTextField }
        func field(_ text: String) throws -> NSTextField {
            try XCTUnwrap(texts.first { $0.stringValue == text }, "no text field showing \(text)")
        }
        return [
            .priority: try field(item.priority?.label ?? ""),
            .kind: try field("✖ Bug"),
            .title: try field(item.title),
            .due: try field("Due today"),
            .status: try field("open"),
        ]
    }

    private enum State { case unselected, emphasisedSelection, inactiveSelection }

    /// A system fill as the row paints it under the cell's appearance, over the list's backdrop.
    private func selectionFill(_ color: NSColor, under cell: NSView) throws -> SelColor {
        let backdrop = try XCTUnwrap(selResolve(NSColor.controlBackgroundColor, in: cell.effectiveAppearance))
        return selOver(try XCTUnwrap(selResolve(color, in: cell.effectiveAppearance)), backdrop)
    }

    /// Put `item`'s row into `state` the way AppKit does, then read the colours its text is drawn in.
    private func colours(_ rig: Rig, _ item: WorkItem, _ state: State) throws -> (cell: NSTableCellView, text: [Part: SelColor]) {
        let cell = try cellFor(rig, item)
        let row = rig.outline.row(for: cell)
        XCTAssertGreaterThanOrEqual(row, 0, "precondition: the cell is in a row")
        switch state {
        case .unselected:
            rig.outline.deselectAll(nil)
            cell.backgroundStyle = .normal
        case .emphasisedSelection:
            rig.outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            cell.backgroundStyle = .emphasized
        case .inactiveSelection:
            rig.outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            cell.backgroundStyle = .normal
        }
        if state != .unselected {
            let rowView = try XCTUnwrap(cell.superview as? NSTableRowView, "the cell sits in its row view")
            XCTAssertTrue(rowView.isSelected, "precondition: the row is selected")
        }
        var out: [Part: SelColor] = [:]
        for (part, field) in try fields(cell, item) {
            out[part] = try XCTUnwrap(selResolve(field.textColor ?? .black, in: cell.effectiveAppearance),
                                      "\(part) has a colour")
        }
        return (cell, out)
    }

    private func cellFor(_ rig: Rig, _ item: WorkItem) throws -> NSTableCellView {
        for row in 0..<rig.outline.numberOfRows {
            if let cell = rig.outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSTableCellView,
               allViews(cell).contains(where: { ($0 as? NSTextField)?.stringValue == item.title }) {
                return cell
            }
        }
        return try XCTUnwrap(nil as NSTableCellView?, "no row shows \(item.title)")
    }

    // MARK: Selected in the key window

    func testEveryTextOnTheEmphasisedSelectionIsWhiteAndAsReadableAsWhiteCanBe() throws {
        for (name, appearance) in appearances {
            let rig = try makeRig(appearance)
            for item in items {
                let (_, text) = try colours(rig, item, .emphasisedSelection)
                // The real fill follows the Mac's accent colour, so the contrast bar is checked
                // against a fixed stand-in for the default blue selection (white on it measures
                // 5.4-6.3:1 across both appearances), never against whatever accent this Mac uses.
                let fill = SelColor(r: 0.04, g: 0.33, b: 0.95, a: 1)
                let white = SelColor(r: 1, g: 1, b: 1, a: 1)
                let bar: CGFloat = 4.5
                for part in Part.allCases {
                    let colour = try XCTUnwrap(text[part])
                    XCTAssertTrue(selClose(colour, white),
                        "\(name) \(item.title): \(part) is \(selDescribe(colour)); on the emphasised selection all text is white")
                    XCTAssertGreaterThanOrEqual(selContrast(colour, on: fill), bar,
                        "\(name) \(item.title): \(part) on \(selDescribe(fill))")
                }
            }
        }
    }

    // MARK: Selected in an inactive window

    func testEveryTextOnTheInactiveSelectionIsReadableOnItsGreyFillInBothAppearances() throws {
        for (name, appearance) in appearances {
            let rig = try makeRig(appearance)
            for item in items {
                let (cell, text) = try colours(rig, item, .inactiveSelection)
                let fill = try selectionFill(NSColor.unemphasizedSelectedContentBackgroundColor, under: cell)
                for part in Part.allCases {
                    let colour = try XCTUnwrap(text[part])
                    let ratio = selContrast(colour, on: fill)
                    XCTAssertGreaterThanOrEqual(ratio, 4.5,
                        "\(name) \(item.title): \(part) \(selDescribe(colour)) on the inactive selection \(selDescribe(fill)) is \(ratio):1")
                }
            }
        }
    }

    // MARK: Not selected

    func testAnUnselectedRowKeepsItsDarkSurfaceColours() throws {
        let rig = try makeRig(appearances[0].appearance)
        func expected(_ colour: NSColor) throws -> SelColor {
            try XCTUnwrap(selResolve(colour, in: appearances[0].appearance))
        }
        let cases: [(WorkItem, Part, NSColor)] = [
            (items[0], .title, Theme.fg),
            (items[0], .kind, Theme.fgMuted),
            (items[0], .status, Theme.fgMuted),
            (items[0], .priority, Theme.redSweater),
            (items[0], .due, Theme.redSweater),      // urgent
            (items[1], .priority, Theme.amber),
            (items[1], .due, Theme.fgMuted),         // not urgent
            (items[2], .priority, Theme.cornflower),
            (items[3], .priority, Theme.fgMuted),
        ]
        for (item, part, colour) in cases {
            let (_, text) = try colours(rig, item, .unselected)
            let actual = try XCTUnwrap(text[part])
            let want = try expected(colour)
            XCTAssertTrue(selClose(actual, want),
                          "\(item.title) \(part) is \(selDescribe(actual)), expected \(selDescribe(want))")
        }
    }

    // MARK: Changing state

    func testARowFollowsItsStateThroughSelectionActivationAndDeselection() throws {
        for (name, appearance) in appearances {
            let rig = try makeRig(appearance)
            let item = items[0]
            let (_, before) = try colours(rig, item, .unselected)

            let (_, emphasised) = try colours(rig, item, .emphasisedSelection)
            _ = try colours(rig, item, .inactiveSelection)
            let (_, emphasisedAgain) = try colours(rig, item, .emphasisedSelection)
            let (_, after) = try colours(rig, item, .unselected)

            for part in Part.allCases {
                let b = try XCTUnwrap(before[part]), e = try XCTUnwrap(emphasised[part])
                let e2 = try XCTUnwrap(emphasisedAgain[part])
                let a = try XCTUnwrap(after[part])
                XCTAssertTrue(selClose(e, SelColor(r: 1, g: 1, b: 1, a: 1)), "\(name) \(part) emphasised: \(selDescribe(e))")
                XCTAssertTrue(selClose(e2, e), "\(name) \(part): activating the window again gives white again")
                XCTAssertTrue(selClose(a, b), "\(name) \(part): a deselected row gets its own colours back (\(selDescribe(a)) vs \(selDescribe(b)))")
            }
        }
    }
}
