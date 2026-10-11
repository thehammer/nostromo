import XCTest
import AppKit

// Slice T1: the "Repo docs" tab of the Teri surface. A thousand docs filed in
// sixteen repos have to be browsable: grouped by repo with a kind breakdown in
// each header, filterable by kind (chips), repo (menu), "has severity" and a
// text search that also reads the doc body, sortable within a group, and
// remembered across a relaunch.
//
// Everything is headless. The real `TeriSurfaceView` goes into an offscreen
// window and is driven through its real controls (chips, menu, search field,
// toggle, sort popup). Expectations are computed here, from the fixture, with
// plain Swift: nothing asks `WorkQuery` what the right answer is. Nothing
// waits a fixed time: state changes are polled for on the run loop, and the
// search debounce is driven by `ManualScheduler`.

// MARK: - Helpers

@discardableResult
private func docsWaitUntil(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return true
}

private func docsSettle(_ seconds: TimeInterval = 0.1) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

private let utcCalendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    c.locale = Locale(identifier: "en_US_POSIX")
    return c
}()

private func iso(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}

/// One repo doc as the daemon would send it.
private func docItem(repo: String = "referral-monitor", kind: String = "bug", title: String = "A doc",
                     path: String? = nil, severity: String? = nil, createdAt: Date? = nil,
                     priority: Int? = nil, searchText: String? = nil) -> WorkItem {
    let rel = path ?? "docs/\(kind)s/\(title.replacingOccurrences(of: " ", with: "-")).md"
    var fields: [String: Any] = [
        "id": "doc:\(repo):\(rel)", "source": "repo_docs", "kind": kind, "repo": repo,
        "title": title, "path": rel, "search_text": searchText ?? title,
    ]
    if let severity { fields["severity"] = severity }
    if let createdAt { fields["created_at"] = iso(createdAt) }
    if let priority { fields["priority"] = ["label": "P\(priority)", "rank": priority] }
    return WorkTestSupport.makeItem(fields)
}

/// `count` docs of `kind` in `repo`, for the header-breakdown tests.
private func docs(_ count: Int, _ kind: String, repo: String = "r") -> [WorkItem] {
    (0..<count).map { docItem(repo: repo, kind: kind, title: "\(kind) \($0)") }
}

// MARK: - The 1,000-doc fixture

/// 1,000 docs in 16 repos, built deterministically. Counts per repo are uneven
/// and several repos tie on count, with the alphabetical order of the tied repos
/// the opposite of the order they are listed in here.
private enum Docs {
    /// (repo, doc count), in the order the fixture is built.
    static let repos: [(name: String, count: Int)] = [
        ("referral-monitor", 150), ("portal", 120), ("payments", 100), ("admin-console", 100),
        ("nostromo", 80), ("callimachus", 70), ("webster", 60), ("teri-agent", 60),
        ("mother", 50), ("harbor", 50), ("fred", 40), ("dataviz", 40),
        ("notifier", 30), ("sentry-bridge", 20), ("docs-site", 20), ("scratch", 10),
    ]

    /// The order the groups must appear in: most docs first, ties by name.
    static let groupOrder = [
        "referral-monitor", "portal", "admin-console", "payments", "nostromo", "callimachus",
        "teri-agent", "webster", "harbor", "mother", "dataviz", "fred", "notifier",
        "docs-site", "sentry-bridge", "scratch",
    ]

    static let kindOrder = ["bug", "feature", "idea", "todo", "wip"]
    static let chipWord = ["bug": "Bugs", "feature": "Features", "idea": "Ideas", "todo": "Todos", "wip": "WIP"]

    private static let kindCycle = ["bug", "bug", "bug", "todo", "todo", "wip", "feature", "bug", "idea", "wip"]
    private static let topics = ["retry", "migration", "webhook", "caching", "audit", "import", "export", "backfill"]
    private static let severities = ["critical", "high", "medium", "low"]
    private static let base = ISO8601DateFormatter().date(from: "2026-10-01T12:00:00Z")!

    /// The word that appears only in the body of exactly three docs.
    static let bodyOnlyWord = "zxqvortex"
    /// (repo index, doc number) of the docs that carry it.
    private static let bodyOnlyDocs: Set<[Int]> = [[0, 10], [1, 5], [5, 40]]

    /// Same items every time (built once).
    static let items: [WorkItem] = {
        var raw: [[String: Any]] = []
        for (r, repo) in repos.enumerated() {
            for n in 0..<repo.count {
                let kind = kindCycle[(n + 3 * r) % kindCycle.count]
                let title = "\(topics[(n + r) % topics.count]) \(repo.name) \(n)"
                let path = "docs/\(kind)s/\(n).md"
                var body = "\(title)\nBackground for \(repo.name) item \(n)"
                if bodyOnlyDocs.contains([r, n]) { body += "\n\(bodyOnlyWord)" }
                var fields: [String: Any] = [
                    "id": "doc:\(repo.name):\(path)", "source": "repo_docs", "kind": kind,
                    "repo": repo.name, "title": title, "path": path, "search_text": body,
                ]
                if n % 3 != 0 { fields["severity"] = severities[n % severities.count] }
                if n % 25 != 24 {   // a few docs have no date
                    fields["created_at"] = iso(base.addingTimeInterval(-Double(n * 7 + r) * 3600))
                }
                raw.append(fields)
            }
        }
        return try! WorkTestSupport.decodeItems(raw)
    }()
}

/// What the user has asked for, in the terms the filter bar offers.
private struct DocFilter {
    var kinds: [String] = []
    var repos: [String] = []
    var query = ""
    var hasSeverity = false
}

/// The rules, written out independently of the app: values within a filter are
/// ORed, filters are ANDed, every search term must be in the title or the body,
/// "has severity" keeps only docs that state one.
private func matches(_ item: WorkItem, _ f: DocFilter, ignoringKind: Bool = false, ignoringRepo: Bool = false) -> Bool {
    if !ignoringKind, !f.kinds.isEmpty, !f.kinds.contains(item.kind) { return false }
    if !ignoringRepo, !f.repos.isEmpty, !f.repos.contains(item.repo ?? "") { return false }
    if f.hasSeverity, item.severity == nil { return false }
    let hay = (item.title + "\n" + item.searchText).lowercased()
    return f.query.lowercased().split(whereSeparator: { $0.isWhitespace }).allSatisfy { hay.contains($0) }
}

private func filtered(_ f: DocFilter) -> [WorkItem] { Docs.items.filter { matches($0, f) } }

private typealias ExpectedGroup = (repo: String, items: [WorkItem])

/// Groups by repo (most docs first, ties by name); within a group by `sort`,
/// undated docs last.
private func expectedGroups(_ items: [WorkItem], sort: WorkSortKey) -> [ExpectedGroup] {
    let byRepo = Dictionary(grouping: items) { $0.repo ?? "" }
    func order(_ group: [WorkItem]) -> [WorkItem] {
        let dated = group.filter { $0.createdAt != nil }
        let undated = group.filter { $0.createdAt == nil }
        switch sort {
        case .newest: return dated.sorted { $0.createdAt! > $1.createdAt! } + undated
        case .oldest: return dated.sorted { $0.createdAt! < $1.createdAt! } + undated
        case .title:  return group.sorted { $0.title.lowercased() < $1.title.lowercased() }
        }
    }
    return byRepo
        .map { (repo: $0.key, items: order($0.value)) }
        .sorted { $0.items.count != $1.items.count ? $0.items.count > $1.items.count : $0.repo < $1.repo }
}

/// Whether `actual` (all rows, group after group) is in the order `sort` gives each group:
/// dated docs in date or title order, undated ones (in any order) after them.
private func rowOrderMatches(_ actual: [String], _ groups: [ExpectedGroup], sort: WorkSortKey) -> Bool {
    var offset = 0
    for group in groups {
        guard offset + group.items.count <= actual.count else { return false }
        let slice = Array(actual[offset..<(offset + group.items.count)])
        offset += group.items.count
        if sort == .title {
            if slice != group.items.map(\.title) { return false }
        } else {
            let dated = group.items.filter { $0.createdAt != nil }.map(\.title)
            let undated = Set(group.items.filter { $0.createdAt == nil }.map(\.title))
            if Array(slice.prefix(dated.count)) != dated || Set(slice.dropFirst(dated.count)) != undated { return false }
        }
    }
    return true
}

// MARK: - Pure behaviour

final class TeriRepoDocsTabTests: XCTestCase {
    private let calendar = utcCalendar
    /// Friday 9 October 2026, mid-afternoon UTC.
    private let now = ISO8601DateFormatter().date(from: "2026-10-09T15:00:00Z")!

    private func daysAgo(_ days: Int, hour: Int = 9, minute: Int = 0) -> Date {
        let start = calendar.startOfDay(for: now)
        let day = calendar.date(byAdding: .day, value: -days, to: start)!
        return calendar.date(byAdding: DateComponents(hour: hour, minute: minute), to: day)!
    }

    private func content(_ item: WorkItem) -> WorkRowContent {
        TeriRepoDocsTab.rowContent(for: item, now: now, calendar: calendar)
    }

    // MARK: Tab configuration

    func testTheTabIsTheRepoDocsTabWithItsFiveKindChipsInAFixedOrder() throws {
        let config = TeriRepoDocsTab.config
        XCTAssertEqual(config.tab, .repoDocs)
        XCTAssertEqual(config.sourceName, "Repo docs")
        let list = try XCTUnwrap(config.list)
        XCTAssertEqual(list.chipFacet, .kind)
        XCTAssertEqual(list.chipValues, ["bug", "feature", "idea", "todo", "wip"])
        XCTAssertEqual(list.chipValues.map(list.chipTitle), ["Bugs", "Features", "Ideas", "Todos", "WIP"])
        XCTAssertEqual(list.menuFacets, [.repo])
        XCTAssertTrue(list.hasSeverityToggle)
        XCTAssertEqual(list.searchPlaceholder, "Filter docs")
    }

    // MARK: Group header

    func testAGroupHeaderShowsTheRepoTheTotalAndTheKindsByCount() {
        let items = docs(74, "bug", repo: "referral-monitor") + docs(33, "todo", repo: "referral-monitor")
            + docs(22, "wip", repo: "referral-monitor") + docs(11, "feature", repo: "referral-monitor")
            + docs(4, "idea", repo: "referral-monitor")

        XCTAssertEqual(TeriRepoDocsTab.groupTitle(repo: "referral-monitor", items: items),
                       "referral-monitor  144 · 74 bugs · 33 todos · 22 wip · 11 features · 4 ideas")
    }

    func testAKindWithExactlyOneDocIsSingular() {
        XCTAssertEqual(TeriRepoDocsTab.groupTitle(repo: "x", items: docs(1, "bug", repo: "x")), "x  1 · 1 bug")
        XCTAssertEqual(TeriRepoDocsTab.groupTitle(repo: "x", items: docs(1, "feature", repo: "x")), "x  1 · 1 feature")
        XCTAssertEqual(TeriRepoDocsTab.groupTitle(repo: "x", items: docs(1, "idea", repo: "x")), "x  1 · 1 idea")
        XCTAssertEqual(TeriRepoDocsTab.groupTitle(repo: "x", items: docs(1, "todo", repo: "x")), "x  1 · 1 todo")
        XCTAssertEqual(TeriRepoDocsTab.groupTitle(repo: "x", items: docs(1, "wip", repo: "x")), "x  1 · 1 wip")
    }

    func testWipIsNeverPluralised() {
        XCTAssertEqual(TeriRepoDocsTab.groupTitle(repo: "x", items: docs(2, "wip", repo: "x")), "x  2 · 2 wip")
    }

    func testKindsWithTheSameCountKeepTheFixedOrderBugFeatureIdeaTodoWip() {
        let items = ["wip", "todo", "idea", "feature", "bug"].flatMap { docs(2, $0, repo: "r") }

        XCTAssertEqual(TeriRepoDocsTab.groupTitle(repo: "r", items: items),
                       "r  10 · 2 bugs · 2 features · 2 ideas · 2 todos · 2 wip")
    }

    func testKindsWithNoDocsAreLeftOutOfTheHeader() {
        let items = docs(3, "feature", repo: "r") + docs(5, "todo", repo: "r")

        XCTAssertEqual(TeriRepoDocsTab.groupTitle(repo: "r", items: items), "r  8 · 5 todos · 3 features")
    }

    // MARK: Filed date

    func testADocFiledEarlierTodayIsFiledToday() {
        XCTAssertEqual(TeriRepoDocsTab.filedText(daysAgo(0, hour: 0, minute: 1), now: now, calendar: calendar), "today")
        XCTAssertEqual(TeriRepoDocsTab.filedText(daysAgo(0, hour: 8), now: now, calendar: calendar), "today")
    }

    func testTheDayDifferenceIsCountedInCalendarDaysNotHours() {
        // 23:59 yesterday is only 15 hours before "now", but it is still yesterday.
        XCTAssertEqual(TeriRepoDocsTab.filedText(daysAgo(1, hour: 23, minute: 59), now: now, calendar: calendar), "yesterday")
        XCTAssertEqual(TeriRepoDocsTab.filedText(daysAgo(1, hour: 0, minute: 0), now: now, calendar: calendar), "yesterday")
    }

    func testADocFiledAFutureDayIsStillFiledToday() {
        XCTAssertEqual(TeriRepoDocsTab.filedText(daysAgo(-3), now: now, calendar: calendar), "today")
    }

    func testADocWithNoDateHasNoFiledText() {
        XCTAssertNil(TeriRepoDocsTab.filedText(nil, now: now, calendar: calendar))
    }

    func testFiledTextSwitchesFromDaysToWeeksToMonthsToYearsAtTheDocumentedBoundaries() {
        let expected: [(days: Int, text: String)] = [
            (2, "2 days ago"), (3, "3 days ago"), (13, "13 days ago"),
            (14, "2 weeks ago"), (20, "2 weeks ago"), (21, "3 weeks ago"), (59, "8 weeks ago"),
            (60, "2 months ago"), (89, "2 months ago"), (90, "3 months ago"), (729, "24 months ago"),
            (730, "2 years ago"), (1094, "2 years ago"), (1095, "3 years ago"),
        ]
        for (days, text) in expected {
            XCTAssertEqual(TeriRepoDocsTab.filedText(daysAgo(days), now: now, calendar: calendar), text,
                           "\(days) days before now")
        }
    }

    // MARK: Row content

    func testEachKindIsLabelledWithItsWordAfterAGlyph() {
        let words = ["bug": "Bug", "feature": "Feature", "idea": "Idea", "todo": "Todo", "wip": "WIP"]
        for (kind, word) in words {
            let text = content(docItem(kind: kind)).kindText
            XCTAssertTrue(text?.hasSuffix(" \(word)") ?? false, "\(kind): \(String(describing: text))")
            XCTAssertGreaterThan(text?.count ?? 0, word.count + 1, "\(kind): the word comes after a glyph")
        }
    }

    func testTheTitleIsShownVerbatim() {
        let title = "Referral status sync drops updates (café, 50% of them)"
        XCTAssertEqual(content(docItem(title: title)).title, title)
    }

    func testTheDateColumnSaysWhenTheDocWasFiledAndIsNeverUrgent() {
        let row = content(docItem(createdAt: daysAgo(3)))
        XCTAssertEqual(row.dueText, "3 days ago")
        XCTAssertFalse(row.dueIsUrgent)
        XCTAssertNil(content(docItem(createdAt: nil)).dueText)
    }

    func testStatusIsTheSeverityOnlyWhenTheDocStatesOne() {
        XCTAssertEqual(content(docItem(severity: "high")).statusText, "Severity: high")
        XCTAssertNil(content(docItem(severity: nil)).statusText)
    }

    func testAVeryLongSeverityIsCutShort() throws {
        let long = String(repeating: "x", count: 40)
        let status = try XCTUnwrap(content(docItem(severity: long)).statusText)

        XCTAssertTrue(status.hasPrefix("Severity: "), status)
        let shown = String(status.dropFirst("Severity: ".count))
        XCTAssertLessThanOrEqual(shown.count, 25, "at most 24 characters plus the ellipsis: \(status)")
        XCTAssertTrue(shown.hasSuffix("…"), status)
        XCTAssertTrue(long.hasPrefix(String(shown.dropLast())), "what is shown is the start of the severity: \(status)")
    }

    func testPriorityIsShownOnlyWhenTheDocHasOne() {
        let with = content(docItem(priority: 2))
        XCTAssertEqual(with.priorityText, "P2")
        XCTAssertEqual(with.priorityRank, 2)
        let without = content(docItem(priority: nil))
        XCTAssertNil(without.priorityText)
        XCTAssertNil(without.priorityRank)
    }

    func testTheAccessibilityLabelReadsKindRepoTitleSeverityAndAge() {
        let item = docItem(repo: "referral-monitor", kind: "bug", title: "Sync drops updates",
                           severity: "high", createdAt: daysAgo(3))

        XCTAssertEqual(content(item).accessibilityLabel,
                       "Bug, referral-monitor, Sync drops updates, severity high, filed 3 days ago")
    }

    func testThePriorityIsReadAfterTheSeverity() {
        let item = docItem(repo: "referral-monitor", kind: "bug", title: "Sync drops updates",
                           severity: "high", createdAt: daysAgo(3), priority: 2)

        XCTAssertEqual(content(item).accessibilityLabel,
                       "Bug, referral-monitor, Sync drops updates, severity high, priority P2, filed 3 days ago")
    }

    func testTheAccessibilityLabelSkipsWhatTheDocDoesNotState() {
        XCTAssertEqual(content(docItem(repo: "r", kind: "todo", title: "T", createdAt: daysAgo(1))).accessibilityLabel,
                       "Todo, r, T, filed yesterday")
        XCTAssertEqual(content(docItem(repo: "r", kind: "feature", title: "T", severity: "low")).accessibilityLabel,
                       "Feature, r, T, severity low")
        XCTAssertEqual(content(docItem(repo: "r", kind: "idea", title: "T")).accessibilityLabel,
                       "Idea, r, T")
        XCTAssertEqual(content(docItem(repo: "r", kind: "wip", title: "T", priority: 1)).accessibilityLabel,
                       "WIP, r, T, priority P1")
    }
}

// MARK: - The tab in the real surface

final class TeriRepoDocsSurfaceTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for name in suites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        suites.removeAll()
        super.tearDown()
    }

    private struct Rig {
        let store: WorkStore
        let defaults: UserDefaults
        let manual: ManualScheduler
        let window: RigWindow
        let surface: TeriSurfaceView
    }

    /// A throwaway defaults suite that already says "show the Repo docs tab".
    private func makeDefaults() -> UserDefaults {
        let name = "nostromo.tests.teriRepoDocs.\(UUID().uuidString)"
        suites.append(name)
        let defaults = UserDefaults(suiteName: name)!
        var state = TeriViewState()
        state.selectedTab = .repoDocs
        state.save(to: defaults)
        return defaults
    }

    /// The real surface on the Repo docs tab, in an offscreen window, with `items` already in the store.
    private func makeRig(defaults: UserDefaults? = nil, items: [WorkItem] = Docs.items,
                         groupErrors: [GroupError] = [], size: NSSize = NSSize(width: 1000, height: 700)) -> Rig {
        let store = WorkStore()
        for (repo, group) in Dictionary(grouping: items, by: { $0.repo ?? "" }) {
            store.apply(snapshot: .repoDocs, group: repo, items: group)
        }
        store.apply(status: SourceStatus(source: .repoDocs, state: .fresh, count: items.count, groupErrors: groupErrors))
        let defaults = defaults ?? makeDefaults()
        let manual = ManualScheduler()
        let window = makeRigWindow(self, size: size)
        let surface = TeriSurfaceView(store: store, defaults: defaults, center: NotificationCenter(),
                                      scheduler: manual.scheduler)
        surface.frame = window.contentView!.bounds
        surface.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(surface)
        surface.layoutSubtreeIfNeeded()
        return Rig(store: store, defaults: defaults, manual: manual, window: window, surface: surface)
    }

    /// A rig that has finished showing every doc.
    private func loadedRig(file: StaticString = #filePath, line: UInt = #line) -> Rig {
        let rig = makeRig()
        XCTAssertTrue(docsWaitUntil { rig.surface.rowTexts.count == Docs.items.count },
                      "the list never showed all \(Docs.items.count) docs (shows \(rig.surface.rowTexts.count))",
                      file: file, line: line)
        return rig
    }

    // MARK: Finding the controls

    private func list(_ rig: Rig) -> WorkListView? {
        rigAllSubviews(of: rig.surface).compactMap { $0 as? WorkListView }.first
    }

    private func listViews(_ rig: Rig) -> [NSView] {
        list(rig).map { rigAllSubviews(of: $0) } ?? []
    }

    /// The kind chips, in the order they are drawn (not the tab strip, not the popups, not the toggle).
    private func chips(_ rig: Rig) -> [NSButton] {
        let table = outline(rig)
        let search = searchField(rig)
        return listViews(rig).compactMap { $0 as? NSButton }.filter { button in
            if button is NSPopUpButton || button.title.isEmpty || button.title == "Has severity" { return false }
            if let table, button.isDescendant(of: table) { return false }   // disclosure triangles
            if let search, button.isDescendant(of: search) { return false }  // the field's own search button
            return true
        }
    }

    private func chip(_ rig: Rig, word: String) -> NSButton? {
        chips(rig).first { $0.title.hasPrefix("\(word) ") }
    }

    private func severityToggle(_ rig: Rig) -> NSButton? {
        listViews(rig).compactMap { $0 as? NSButton }.first { $0.title == "Has severity" && !($0 is NSPopUpButton) }
    }

    private func repoMenu(_ rig: Rig) -> NSPopUpButton? {
        listViews(rig).compactMap { $0 as? NSPopUpButton }.first { $0.pullsDown }
    }

    private func sortPopup(_ rig: Rig) -> NSPopUpButton? {
        listViews(rig).compactMap { $0 as? NSPopUpButton }.first { !$0.pullsDown }
    }

    private func searchField(_ rig: Rig) -> NSSearchField? {
        listViews(rig).compactMap { $0 as? NSSearchField }.first
    }

    private func outline(_ rig: Rig) -> NSOutlineView? {
        listViews(rig).compactMap { $0 as? NSOutlineView }.first
    }

    // MARK: Driving the controls

    /// What a click does to a toggle button: flip it, then send its action.
    private func click(_ button: NSButton) {
        if button.state == .on { button.state = .off } else { button.state = .on }
        button.sendAction(button.action, to: button.target)
    }

    private func clickChip(_ rig: Rig, _ kind: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let button = chip(rig, word: Docs.chipWord[kind]!) else {
            return XCTFail("no chip for \(kind): \(chips(rig).map(\.title))", file: file, line: line)
        }
        click(button)
    }

    private func chooseFromRepoMenu(_ rig: Rig, titled predicate: (String) -> Bool,
                                    file: StaticString = #filePath, line: UInt = #line) {
        guard let item = repoMenu(rig)?.menu?.items.first(where: { predicate($0.title) }),
              let action = item.action else {
            return XCTFail("no such item in the repo menu: \(repoMenu(rig)?.menu?.items.map(\.title) ?? [])",
                           file: file, line: line)
        }
        NSApplication.shared.sendAction(action, to: item.target, from: item)
    }

    private func chooseRepo(_ rig: Rig, _ repo: String, file: StaticString = #filePath, line: UInt = #line) {
        chooseFromRepoMenu(rig, titled: { $0.hasPrefix("\(repo) (") }, file: file, line: line)
    }

    private func typeSearch(_ rig: Rig, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let field = searchField(rig) else { return XCTFail("no search field", file: file, line: line) }
        field.stringValue = text
        field.sendAction(field.action, to: field.target)
        rig.manual.fireAll()   // the debounce
    }

    private func setHasSeverity(_ rig: Rig, _ on: Bool, file: StaticString = #filePath, line: UInt = #line) {
        guard let toggle = severityToggle(rig) else { return XCTFail("no Has severity toggle", file: file, line: line) }
        toggle.state = on ? .on : .off
        toggle.sendAction(toggle.action, to: toggle.target)
    }

    private func chooseSort(_ rig: Rig, _ title: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let popup = sortPopup(rig) else { return XCTFail("no sort popup", file: file, line: line) }
        guard popup.itemTitles.contains(title) else {
            return XCTFail("no \(title) in the sort popup: \(popup.itemTitles)", file: file, line: line)
        }
        popup.selectItem(withTitle: title)
        popup.sendAction(popup.action, to: popup.target)
    }

    /// Runs what is pending twice: the first pass lands a debounced search, the second
    /// the view-state save that the change scheduled.
    private func flush(_ rig: Rig) {
        rig.manual.fireAll()
        rig.manual.fireAll()
    }

    // MARK: Asserting what is shown

    /// The list shows exactly what the rules say for `f` and `sort`: the groups in order
    /// with their headers, the rows within each group in order.
    private func assertListShows(_ rig: Rig, _ f: DocFilter, sort: WorkSortKey = .newest,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let matching = filtered(f)
        let groups = expectedGroups(matching, sort: sort)
        let headers = groups.map { TeriRepoDocsTab.groupTitle(repo: $0.repo, items: $0.items) }
        // A sort change keeps the same rows under the same headers: wait for the ORDER too.
        let settled = docsWaitUntil {
            rig.surface.rowTexts.count == matching.count && rig.surface.groupHeaderTexts == headers
                && rowOrderMatches(rig.surface.rowTexts.map(\.title), groups, sort: sort)
        }
        XCTAssertTrue(settled, """
            the list never settled on \(matching.count) rows under \(headers.count) headers; shows \
            \(rig.surface.rowTexts.count) rows under \(rig.surface.groupHeaderTexts.count) headers
            """, file: file, line: line)
        XCTAssertEqual(rig.surface.groupHeaderTexts, headers, file: file, line: line)

        let actual = rig.surface.rowTexts.map(\.title)
        var offset = 0
        for group in groups {
            guard offset + group.items.count <= actual.count else { break }
            let slice = Array(actual[offset..<(offset + group.items.count)])
            offset += group.items.count
            if sort == .title {
                XCTAssertEqual(slice, group.items.map(\.title), "rows of \(group.repo) by title", file: file, line: line)
            } else {
                let dated = group.items.filter { $0.createdAt != nil }.map(\.title)
                let undated = group.items.filter { $0.createdAt == nil }.map(\.title)
                XCTAssertEqual(Array(slice.prefix(dated.count)), dated, "dated rows of \(group.repo) by \(sort)",
                               file: file, line: line)
                XCTAssertEqual(Set(slice.dropFirst(dated.count)), Set(undated),
                               "undated rows of \(group.repo) come last", file: file, line: line)
            }
        }
    }

    /// The chips and the repo menu show the counts the faceted-search rules give for `f`:
    /// each facet's counts ignore that facet's own filter and respect every other one.
    private func assertFilterBarCounts(_ rig: Rig, _ f: DocFilter, file: StaticString = #filePath, line: UInt = #line) {
        let expectedChips = Docs.kindOrder.map { kind in
            "\(Docs.chipWord[kind]!) \(Docs.items.filter { $0.kind == kind && matches($0, f, ignoringKind: true) }.count)"
        }
        XCTAssertEqual(chips(rig).map(\.title), expectedChips, "kind chips", file: file, line: line)
        for (kind, button) in zip(Docs.kindOrder, chips(rig)) {
            XCTAssertEqual(button.state == .on, f.kinds.contains(kind), "the \(kind) chip's on/off state",
                           file: file, line: line)
        }

        var expectedRepos: [String: Int] = [:]
        for item in Docs.items where matches(item, f, ignoringRepo: true) { expectedRepos[item.repo ?? "", default: 0] += 1 }
        var shownRepos: [String: Int] = [:]
        var checked: Set<String> = []
        for item in repoMenu(rig)?.menu?.items.dropFirst() ?? [] {
            guard let open = item.title.lastIndex(of: "("), item.title.hasSuffix(")"), open > item.title.startIndex,
                  let count = Int(item.title[item.title.index(after: open)..<item.title.index(before: item.title.endIndex)])
            else { continue }   // the title item and "All" carry no count
            let repo = String(item.title[..<open]).trimmingCharacters(in: .whitespaces)
            shownRepos[repo] = count
            if item.state == .on { checked.insert(repo) }
        }
        XCTAssertEqual(shownRepos.filter { $0.value > 0 }, expectedRepos, "repo menu counts", file: file, line: line)
        XCTAssertEqual(checked, Set(f.repos), "the repo menu ticks the chosen repos", file: file, line: line)
    }

    // MARK: The filter bar

    func testTheFilterBarOffersKindChipsARepoMenuASortPopupAndASeverityToggle() {
        let rig = loadedRig()

        XCTAssertEqual(chips(rig).map(\.title), ["Bugs 400", "Features 100", "Ideas 100", "Todos 200", "WIP 200"])
        XCTAssertEqual(searchField(rig)?.placeholderString, "Filter docs")
        XCTAssertEqual(sortPopup(rig)?.itemTitles, ["Newest", "Oldest", "Title"])
        XCTAssertNotNil(severityToggle(rig), "a Has severity toggle")
        XCTAssertEqual(repoMenu(rig)?.menu?.items.dropFirst().first?.title, "All",
                       "the repo menu starts with All, right after its title")
    }

    func testTheChipsForAKindWithNoDocsLeftStayAndShowZero() {
        let rig = loadedRig()

        typeSearch(rig, Docs.bodyOnlyWord)
        let f = DocFilter(query: Docs.bodyOnlyWord)
        assertListShows(rig, f)

        let counts = chips(rig).map(\.title)
        XCTAssertEqual(counts.count, 5, "every kind keeps its chip: \(counts)")
        assertFilterBarCounts(rig, f)
        XCTAssertTrue(counts.contains { $0.hasSuffix(" 0") }, "at least one kind has no hit: \(counts)")
    }

    // MARK: Groups

    func testReposAreGroupedMostDocsFirstThenByNameWithTheKindBreakdownInEachHeader() {
        let rig = loadedRig()

        let headers = rig.surface.groupHeaderTexts
        XCTAssertEqual(headers.count, 16)
        XCTAssertEqual(headers.map { $0.components(separatedBy: "  ").first ?? "" }, Docs.groupOrder)
        for (i, repo) in Docs.groupOrder.enumerated() {
            let count = Docs.items.filter { $0.repo == repo }.count
            XCTAssertEqual(headers[i], "\(repo)  \(count) · \(breakdown(of: repo))")
        }
        XCTAssertTrue(headers[0].hasPrefix("referral-monitor  150 · "), headers[0])
        assertListShows(rig, DocFilter())
    }

    /// "4 bugs · 2 wip …" for `repo`, counted from the fixture: biggest kind first, ties bug, feature, idea, todo, wip.
    private func breakdown(of repo: String) -> String {
        let mine = Docs.items.filter { $0.repo == repo }
        let words = ["bug": ("bug", "bugs"), "feature": ("feature", "features"), "idea": ("idea", "ideas"),
                     "todo": ("todo", "todos"), "wip": ("wip", "wip")]
        var counted: [(kind: String, n: Int)] = []
        for kind in Docs.kindOrder {
            let n = mine.filter { $0.kind == kind }.count
            if n > 0 { counted.append((kind: kind, n: n)) }
        }
        let ordered = counted.enumerated()
            .sorted { a, b in a.element.n != b.element.n ? a.element.n > b.element.n : a.offset < b.offset }
            .map { $0.element }
        return ordered.map { entry in
            "\(entry.n) " + (entry.n == 1 ? words[entry.kind]!.0 : words[entry.kind]!.1)
        }.joined(separator: " · ")
    }

    // MARK: Filtering

    func testChipCountsFollowTheFacetRulesUnderKindRepoAndSearchTogether() {
        let rig = loadedRig()
        var f = DocFilter()

        clickChip(rig, "bug")
        f.kinds = ["bug"]
        assertListShows(rig, f)
        assertFilterBarCounts(rig, f)

        chooseRepo(rig, "portal")
        f.repos = ["portal"]
        assertListShows(rig, f)
        assertFilterBarCounts(rig, f)

        typeSearch(rig, "webhook")
        f.query = "webhook"
        assertListShows(rig, f)
        assertFilterBarCounts(rig, f)

        // Spot check, counted by hand from the fixture: portal's docs about webhooks, by kind.
        XCTAssertEqual(chips(rig).map(\.title), ["Bugs 6", "Features 3", "Ideas 3", "Todos 3", "WIP 0"])
        XCTAssertEqual(rig.surface.rowTexts.count, 6)
    }

    func testTheRepoMenuAcceptsSeveralReposAndCountsIgnoreTheRepoFilter() {
        let rig = loadedRig()
        var f = DocFilter()

        clickChip(rig, "bug")
        f.kinds = ["bug"]
        assertListShows(rig, f)

        chooseRepo(rig, "portal")
        f.repos = ["portal"]
        assertListShows(rig, f)

        chooseRepo(rig, "payments")
        f.repos = ["portal", "payments"]
        assertListShows(rig, f)
        assertFilterBarCounts(rig, f)
        XCTAssertEqual(rig.surface.groupHeaderTexts.count, 2)
    }

    func testChoosingAllInTheRepoMenuClearsTheRepoFilter() {
        let rig = loadedRig()
        chooseRepo(rig, "portal")
        chooseRepo(rig, "payments")
        assertListShows(rig, DocFilter(repos: ["portal", "payments"]))

        chooseFromRepoMenu(rig, titled: { $0 == "All" })

        assertListShows(rig, DocFilter())
        assertFilterBarCounts(rig, DocFilter())
    }

    func testChipsAndTheRepoMenuRespectHasSeverity() {
        let rig = loadedRig()
        var f = DocFilter()

        setHasSeverity(rig, true)
        f.hasSeverity = true
        assertListShows(rig, f)
        assertFilterBarCounts(rig, f)

        chooseRepo(rig, "payments")
        f.repos = ["payments"]
        assertListShows(rig, f)
        assertFilterBarCounts(rig, f)
    }

    // MARK: Search

    func testSearchFindsDocsByTextThatIsOnlyInTheirBody() {
        let rig = loadedRig()
        let hits = filtered(DocFilter(query: Docs.bodyOnlyWord))
        XCTAssertEqual(hits.count, 3, "precondition: exactly three docs carry the word")
        XCTAssertTrue(hits.allSatisfy { !$0.title.lowercased().contains(Docs.bodyOnlyWord) },
                      "precondition: the word is in no title")

        typeSearch(rig, Docs.bodyOnlyWord)

        assertListShows(rig, DocFilter(query: Docs.bodyOnlyWord))
        XCTAssertEqual(Set(rig.surface.rowTexts.map(\.title)), Set(hits.map(\.title)))
    }

    func testTheSearchRunsOnceTypingPausesNotOnEveryKeystroke() throws {
        let rig = loadedRig()
        let field = try XCTUnwrap(searchField(rig))

        field.stringValue = Docs.bodyOnlyWord
        field.sendAction(field.action, to: field.target)
        docsSettle(0.2)
        XCTAssertEqual(rig.surface.rowTexts.count, Docs.items.count, "nothing is filtered before the debounce runs")

        rig.manual.fireAll()
        assertListShows(rig, DocFilter(query: Docs.bodyOnlyWord))
    }

    func testSearchTermsAreANDedAcrossTitleAndBody() {
        let rig = loadedRig()
        // One term only in the body, one only in the title: both must be present.
        let target = Docs.items.first { $0.searchText.contains(Docs.bodyOnlyWord) }!
        let titleWord = String(target.title.split(separator: " ")[0])
        let f = DocFilter(query: "\(titleWord) \(Docs.bodyOnlyWord)")

        typeSearch(rig, f.query)

        assertListShows(rig, f)
        XCTAssertTrue(rig.surface.rowTexts.map(\.title).contains(target.title))
    }

    // MARK: Has severity

    func testDocsWithoutASeverityStayVisibleUntilHasSeverityIsSwitchedOn() {
        let rig = loadedRig()
        XCTAssertTrue(rig.surface.rowTexts.contains { $0.statusText == nil },
                      "precondition: by default docs with no severity are listed")

        setHasSeverity(rig, true)
        assertListShows(rig, DocFilter(hasSeverity: true))
        XCTAssertTrue(rig.surface.rowTexts.allSatisfy { $0.statusText?.hasPrefix("Severity: ") == true },
                      "with the toggle on, every listed doc states a severity")
        XCTAssertLessThan(rig.surface.rowTexts.count, Docs.items.count)

        setHasSeverity(rig, false)
        assertListShows(rig, DocFilter())
        XCTAssertTrue(rig.surface.rowTexts.contains { $0.statusText == nil }, "switching it off brings them back")
    }

    // MARK: Failed repos

    func testARepoThatFailedToLoadIsMarkedInItsHeaderAndOthersAreUnaffected() {
        let errors = [GroupError(group: "mother", reason: "git pull failed"),
                      GroupError(group: "ghost-repo", reason: "clone failed: no access")]
        let rig = makeRig(groupErrors: errors)
        XCTAssertTrue(docsWaitUntil { rig.surface.rowTexts.count == Docs.items.count })
        XCTAssertTrue(docsWaitUntil { rig.surface.groupHeaderTexts.count == 17 },
                      "a repo with an error but no docs still gets a header: \(rig.surface.groupHeaderTexts)")

        let headers = rig.surface.groupHeaderTexts
        let groups = expectedGroups(Docs.items, sort: .newest)
        let plain = groups.map { TeriRepoDocsTab.groupTitle(repo: $0.repo, items: $0.items) }

        // The repo that has docs: its normal header, then the marker and the reason.
        let motherIndex = Docs.groupOrder.firstIndex(of: "mother")!
        XCTAssertEqual(headers[motherIndex], "\(plain[motherIndex]) ⚠ git pull failed")
        // Every other repo's header is exactly what it was.
        for (i, title) in plain.enumerated() where i != motherIndex {
            XCTAssertEqual(headers[i], title)
        }
        // The repo with no docs comes after the repos that have some.
        XCTAssertTrue(headers[16].hasPrefix("ghost-repo"), headers[16])
        XCTAssertTrue(headers[16].contains("⚠"), headers[16])
        XCTAssertTrue(headers[16].hasSuffix("clone failed: no access"), headers[16])
        XCTAssertEqual(rig.surface.rowTexts.count, Docs.items.count, "a header-only group adds no rows")
    }

    func testAFailedRepoKeepsItsHeaderWhenAFilterHidesAllOfItsDocs() {
        let rig = makeRig(groupErrors: [GroupError(group: "mother", reason: "git pull failed")])
        XCTAssertTrue(docsWaitUntil { rig.surface.rowTexts.count == Docs.items.count })

        typeSearch(rig, Docs.bodyOnlyWord)
        XCTAssertTrue(docsWaitUntil { rig.surface.rowTexts.count == 3 })

        let headers = rig.surface.groupHeaderTexts
        XCTAssertEqual(headers.count, 4, "three repos with a hit, then the failed one: \(headers)")
        XCTAssertTrue(headers.last?.hasPrefix("mother") ?? false, "\(headers)")
        XCTAssertTrue(headers.last?.hasSuffix("⚠ git pull failed") ?? false, "\(headers)")
        XCTAssertFalse(headers.dropLast().contains { $0.contains("⚠") }, "the healthy repos are unmarked: \(headers)")
    }

    // MARK: Sort

    func testTheSortPopupOrdersDocsWithinEachGroupByNewestOldestOrTitle() {
        let rig = loadedRig()
        assertListShows(rig, DocFilter(), sort: .newest)

        chooseSort(rig, "Oldest")
        assertListShows(rig, DocFilter(), sort: .oldest)

        chooseSort(rig, "Title")
        assertListShows(rig, DocFilter(), sort: .title)

        chooseSort(rig, "Newest")
        assertListShows(rig, DocFilter(), sort: .newest)
    }

    func testSortingNeverReordersTheGroupsThemselves() {
        let rig = loadedRig()

        chooseSort(rig, "Title")
        assertListShows(rig, DocFilter(), sort: .title)

        XCTAssertEqual(rig.surface.groupHeaderTexts.map { $0.components(separatedBy: "  ").first ?? "" }, Docs.groupOrder)
    }

    // MARK: Remembered across a relaunch

    func testFiltersSearchSortAndSeverityComeBackWhenTheSurfaceIsOpenedAgain() {
        let first = loadedRig()
        var f = DocFilter()
        clickChip(first, "bug")
        f.kinds = ["bug"]
        assertListShows(first, f)
        chooseRepo(first, "portal")
        f.repos = ["portal"]
        assertListShows(first, f)
        chooseRepo(first, "payments")
        f.repos = ["portal", "payments"]
        assertListShows(first, f)
        typeSearch(first, "webhook")
        f.query = "webhook"
        assertListShows(first, f)
        setHasSeverity(first, true)
        f.hasSeverity = true
        assertListShows(first, f)
        chooseSort(first, "Oldest")
        assertListShows(first, f, sort: .oldest)
        XCTAssertEqual(filtered(f).count, 7, "precondition: the fixture gives this combination 7 docs")
        flush(first)

        let second = makeRig(defaults: first.defaults)

        XCTAssertEqual(second.surface.selectedTab, .repoDocs)
        assertListShows(second, f, sort: .oldest)
        assertFilterBarCounts(second, f)
        XCTAssertEqual(searchField(second)?.stringValue, "webhook")
        XCTAssertEqual(severityToggle(second)?.state, .on)
        XCTAssertEqual(sortPopup(second)?.titleOfSelectedItem, "Oldest")
        XCTAssertEqual(second.surface.rowTexts.map(\.title), first.surface.rowTexts.map(\.title))
        XCTAssertEqual(second.surface.groupHeaderTexts, first.surface.groupHeaderTexts)
    }

    func testCollapsedGroupsAndTheSelectedDocComeBackWhenTheSurfaceIsOpenedAgain() throws {
        let first = loadedRig()
        let f = DocFilter(kinds: ["bug"])
        clickChip(first, "bug")
        assertListShows(first, f)
        let groups = expectedGroups(filtered(f), sort: .newest)
        let collapsed = groups[0], open = groups[1]

        let outline = try XCTUnwrap(outline(first))
        outline.collapseItem(try XCTUnwrap(outline.item(atRow: 0)))
        XCTAssertTrue(docsWaitUntil { first.surface.rowTexts.count == filtered(f).count - collapsed.items.count },
                      "precondition: collapsing the first group hides its docs")
        let pick = open.items[2]
        first.surface.selectItem(id: pick.id)
        XCTAssertEqual(first.surface.selectedItemId, pick.id)
        flush(first)

        let second = makeRig(defaults: first.defaults)

        let expectedHeaders = groups.map { TeriRepoDocsTab.groupTitle(repo: $0.repo, items: $0.items) }
        XCTAssertTrue(docsWaitUntil { second.surface.groupHeaderTexts == expectedHeaders }, "\(second.surface.groupHeaderTexts)")
        XCTAssertTrue(docsWaitUntil { second.surface.rowTexts.count == filtered(f).count - collapsed.items.count },
                      "the first group is still collapsed: \(second.surface.rowTexts.count) rows")
        XCTAssertEqual(second.surface.rowTexts.map(\.title), first.surface.rowTexts.map(\.title))
        XCTAssertFalse(second.surface.rowTexts.map(\.title).contains(collapsed.items[0].title))
        XCTAssertEqual(second.surface.selectedItemId, pick.id)
        XCTAssertTrue(docsWaitUntil { second.surface.detailTitle == pick.title },
                      "the detail pane shows the remembered doc: \(String(describing: second.surface.detailTitle))")
    }

    // MARK: Scrolling a thousand rows

    func testScrollingThroughAThousandRowsStaysResponsiveAndReusesItsRowViews() throws {
        let rig = loadedRig()
        docsSettle()
        let outline = try XCTUnwrap(outline(rig))
        XCTAssertEqual(outline.numberOfRows, Docs.items.count + 16, "precondition: every group is expanded")

        // REAL elapsed time, as in WorkStoreTests: a run-loop pump may return late under load,
        // so the bound is generous. It guards against pathological layout, not a frame budget.
        let started = CFAbsoluteTimeGetCurrent()
        rig.surface.layoutSubtreeIfNeeded()
        let total = outline.numberOfRows
        for step in 1...20 {
            outline.scrollRowToVisible(total * step / 20 - 1)
            rig.surface.layoutSubtreeIfNeeded()
            if let visible = Range(outline.rows(in: outline.visibleRect)) {
                for row in visible { _ = outline.view(atColumn: 0, row: row, makeIfNecessary: true) }
            }
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - started

        XCTAssertEqual(NSMaxRange(outline.rows(in: outline.visibleRect)), total, "the walk reached the bottom")
        XCTAssertLessThanOrEqual(elapsed, 5, "laying out and scrolling 1,000 rows took \(elapsed) s")
        let cells = rigAllSubviews(of: outline).filter { $0 is NSTableCellView }.count
        XCTAssertGreaterThan(cells, 0, "precondition: rows were drawn")
        XCTAssertLessThan(cells, 150, "\(cells) live row views for \(total) rows: rows are not being reused")
    }

    // MARK: Filter cost

    func testFilteringAndSearchingAThousandDocsTakesUnder100ms() {
        let store = WorkStore()
        for (repo, group) in Dictionary(grouping: Docs.items, by: { $0.repo ?? "" }) {
            store.apply(snapshot: .repoDocs, group: repo, items: group)
        }
        let f = DocFilter(kinds: ["bug", "todo"], repos: ["referral-monitor", "portal", "payments", "nostromo"],
                          query: "retry", hasSeverity: true)
        var filter = WorkFilter()
        filter.kinds = f.kinds
        filter.repos = f.repos
        filter.query = f.query
        filter.hasSeverity = true
        func run() -> WorkListSnapshot {
            store.listSnapshot(source: .repoDocs, filter: filter, sort: .newest, facets: [.kind, .repo])
        }

        _ = run()   // warm-up
        var best = TimeInterval.infinity
        var snapshot = run()
        for _ in 0..<5 {
            let started = CFAbsoluteTimeGetCurrent()
            snapshot = run()
            best = min(best, CFAbsoluteTimeGetCurrent() - started)
        }

        XCTAssertLessThanOrEqual(best, 0.1, "best of 5 took \(best * 1000) ms")
        let expected = expectedGroups(filtered(f), sort: .newest)
        XCTAssertEqual(expected.map(\.repo), ["portal", "referral-monitor", "payments", "nostromo"],
                       "precondition: the fixture's expected groups (ties by name)")
        XCTAssertEqual(snapshot.groups.map(\.key), expected.map(\.repo))
        XCTAssertEqual(snapshot.groups.map { $0.items.count }, expected.map { $0.items.count })
        XCTAssertEqual(snapshot.totalCount, Docs.items.count)
        XCTAssertEqual(snapshot.filteredCount, filtered(f).count)
        var kindCounts: [String: Int] = [:]
        for item in Docs.items where matches(item, f, ignoringKind: true) { kindCounts[item.kind, default: 0] += 1 }
        var repoCounts: [String: Int] = [:]
        for item in Docs.items where matches(item, f, ignoringRepo: true) { repoCounts[item.repo ?? "", default: 0] += 1 }
        XCTAssertEqual(snapshot.facetCounts[.kind], kindCounts)
        XCTAssertEqual(snapshot.facetCounts[.repo], repoCounts)
    }
}
