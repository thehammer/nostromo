import XCTest
import AppKit

// Slice T2: the Jira tab of the Teri surface. The real `TeriSurfaceView` goes into
// an offscreen window that is never shown (same pattern as TeriSurfaceViewTests),
// fed by a `WorkStore` we seed ourselves. Nothing here asserts on pixels or waits
// a fixed time: changes are polled for on the run loop.

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

private final class FrameLog {
    var frames: [WorkClientMessage] = []
}

private let iso = ISO8601DateFormatter()

/// An issue as the daemon would send it: `jira:<KEY>`, title = summary,
/// search_text = "KEY summary".
private func issue(_ key: String, _ summary: String, project: String? = nil, status: String = "To Do",
                  category: String? = "to_do", priority: (String, Int)? = nil,
                  updated: String? = nil, searchExtra: String = "") -> WorkItem {
    var f: [String: Any] = [
        "id": "jira:\(key)", "source": "jira", "kind": "Task", "title": summary,
        "project": project ?? String(key.split(separator: "-")[0]),
        "status": status, "search_text": "\(key) \(summary)\(searchExtra)",
    ]
    if let category { f["status_category"] = category }
    if let priority { f["priority"] = ["label": priority.0, "rank": priority.1] }
    if let updated { f["updated_at"] = updated }
    return WorkTestSupport.makeItem(f)
}

private func seedJira(_ store: WorkStore, _ items: [WorkItem], state: SourceState = .fresh,
                      reason: String? = nil, retryAt: Date? = nil) {
    store.apply(snapshot: .jira, group: nil, items: items)
    store.apply(status: SourceStatus(source: .jira, state: state, reason: reason, retryAt: retryAt, count: items.count))
}

// MARK: - Row content (pure)

final class TeriJiraRowContentTests: XCTestCase {
    private let now = iso.date(from: "2026-10-09T15:00:00Z")!

    private func content(_ item: WorkItem, at now: Date? = nil) -> WorkRowContent {
        TeriJiraTab.rowContent(for: item, now: now ?? self.now)
    }

    private func ago(_ seconds: TimeInterval) -> String {
        TeriJiraTab.updatedText(since: now.addingTimeInterval(-seconds), now: now)
    }

    func testTheRowReadsKeyThenSummaryWithPriorityStatusAndAge() {
        let item = issue("RM-12", "Summary", status: "In Review", category: "in_progress",
                         priority: ("High", 2), updated: "2026-10-06T15:00:00Z")   // 3 days before now
        let row = content(item)

        XCTAssertEqual(row.title, "RM-12 Summary")
        XCTAssertEqual(row.priorityText, "High", "priority is shown by name, as text")
        XCTAssertEqual(row.priorityRank, 2)
        XCTAssertEqual(row.statusText, "In Review")
        XCTAssertEqual(row.dueText, "updated 3 d ago")
    }

    func testAnIssueWithoutPriorityOrUpdateTimeShowsNeitherAndDoesNotCrash() {
        let row = content(issue("RM-1", "Bare"))

        XCTAssertEqual(row.title, "RM-1 Bare")
        XCTAssertNil(row.priorityText)
        XCTAssertNil(row.priorityRank)
        XCTAssertNil(row.dueText)
        XCTAssertEqual(row.statusText, "To Do")
    }

    func testTheAgeIsSpelledOutInTheLargestWholeUnit() {
        XCTAssertEqual(ago(0), "updated just now")
        XCTAssertEqual(ago(59), "updated just now")
        XCTAssertEqual(ago(60), "updated 1 min ago")
        XCTAssertEqual(ago(5 * 60 + 30), "updated 5 min ago")
        XCTAssertEqual(ago(3_599), "updated 59 min ago")
        XCTAssertEqual(ago(3_600), "updated 1 h ago")
        XCTAssertEqual(ago(3 * 3_600), "updated 3 h ago")
        XCTAssertEqual(ago(86_399), "updated 23 h ago")
        XCTAssertEqual(ago(86_400), "updated 1 d ago")
        XCTAssertEqual(ago(3 * 86_400 + 100), "updated 3 d ago")
        XCTAssertEqual(ago(40 * 86_400), "updated 40 d ago")
    }

    func testAnUpdateTimeInTheFutureNeverShowsANegativeAge() {
        XCTAssertEqual(ago(-120), "updated just now", "clock skew between daemon and app")
    }

    func testTheAccessibilityLabelNamesSourceTypeTitlePriorityStatusAndAge() {
        let item = issue("RM-12", "Summary", status: "In Review", priority: ("High", 2),
                         updated: "2026-10-06T15:00:00Z")
        let label = content(item).accessibilityLabel

        XCTAssertTrue(label.contains("Jira"), label)
        XCTAssertTrue(label.contains("Task"), "the issue type: \(label)")
        XCTAssertTrue(label.contains("RM-12 Summary"), label)
        XCTAssertTrue(label.contains("High"), label)
        XCTAssertTrue(label.contains("In Review"), label)
        XCTAssertTrue(label.contains("3 d ago"), label)
    }

    func testGroupTitlesAreReadableNames() {
        XCTAssertEqual(TeriJiraTab.groupTitle(forKey: "in_progress"), "In Progress")
        XCTAssertEqual(TeriJiraTab.groupTitle(forKey: "to_do"), "To Do")
        XCTAssertEqual(TeriJiraTab.groupTitle(forKey: "other"), "Other")
        XCTAssertEqual(TeriJiraTab.groupTitle(forKey: nil), "Other")
        XCTAssertEqual(TeriJiraTab.groupTitle(forKey: "something_new"), "Other")
    }

    func testTheTabIsWiredToJiraWithProjectAndStatusMenusAndASearchBox() {
        let config = TeriJiraTab.config
        XCTAssertEqual(config.tab, .jira)
        XCTAssertEqual(config.sourceName, "Jira")
        XCTAssertEqual(config.list?.menuFacets, [.project, .status])
        XCTAssertNil(config.list?.chipFacet)
        XCTAssertFalse(config.emptyMessage.isEmpty)
    }
}

// MARK: - The tab in the surface

final class TeriJiraTabTests: XCTestCase {
    private var suites: [String] = []

    override func tearDown() {
        for name in suites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        suites.removeAll()
        super.tearDown()
    }

    private struct Rig {
        let store: WorkStore
        let window: RigWindow
        let surface: TeriSurfaceView
        let log: FrameLog
    }

    private func makeRig(seed: (WorkStore) -> Void = { _ in }) -> Rig {
        let store = WorkStore()
        let log = FrameLog()
        store.sendFrame = { log.frames.append($0) }
        seed(store)
        let name = "nostromo.tests.teriJira.\(UUID().uuidString)"
        suites.append(name)
        let window = makeRigWindow(self, size: NSSize(width: 1000, height: 700))
        let surface = TeriSurfaceView(store: store, defaults: UserDefaults(suiteName: name)!,
                                      center: NotificationCenter())
        surface.frame = window.contentView!.bounds
        surface.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(surface)
        surface.layoutSubtreeIfNeeded()
        surface.select(.jira)
        surface.layoutSubtreeIfNeeded()
        return Rig(store: store, window: window, surface: surface, log: log)
    }

    private func titles(_ rig: Rig) -> [String] { rig.surface.rowTexts.map(\.title) }

    /// Wait for the list to show exactly `expected` (in order), then assert it.
    private func expectRows(_ rig: Rig, _ expected: [String], _ message: @autoclosure () -> String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
        _ = waitUntil { self.titles(rig) == expected }
        XCTAssertEqual(titles(rig), expected, message(), file: file, line: line)
    }

    // MARK: Grouping and order

    private func mixedIssues() -> [WorkItem] {
        // Deliberately seeded in the "wrong" order: the surface must sort.
        [
            issue("RM-5", "Parked idea", status: "Backlog", category: "other", priority: ("Low", 4),
                  updated: "2026-10-09T10:00:00Z"),
            issue("RM-4", "Plan the quarter", status: "To Do", category: "to_do", priority: ("Medium", 3),
                  updated: "2026-10-02T10:00:00Z"),
            issue("RM-1", "Fix the webhook", status: "In Progress", category: "in_progress", priority: ("High", 2),
                  updated: "2026-10-01T10:00:00Z"),
            issue("RM-2", "Rotate the keys", status: "In Review", category: "in_progress", priority: ("Highest", 1),
                  updated: "2026-09-01T10:00:00Z"),
            issue("RM-3", "Retry backoff", status: "In Progress", category: "in_progress", priority: ("High", 2),
                  updated: "2026-10-05T10:00:00Z"),
        ]
    }

    func testIssuesAreGroupedInProgressThenToDoThenOther() {
        let rig = makeRig(seed: { seedJira($0, self.mixedIssues()) })

        XCTAssertTrue(waitUntil { rig.surface.rowTexts.count == 5 })
        XCTAssertEqual(rig.surface.groupHeaderTexts, ["In Progress", "To Do", "Other"])
    }

    func testWithinAGroupHigherPriorityComesFirstThenTheMostRecentlyUpdated() {
        let rig = makeRig(seed: { seedJira($0, self.mixedIssues()) })

        expectRows(rig, [
            "RM-2 Rotate the keys",     // In Progress, Highest
            "RM-3 Retry backoff",       // In Progress, High, updated 10-05 (newer)
            "RM-1 Fix the webhook",     // In Progress, High, updated 10-01
            "RM-4 Plan the quarter",    // To Do
            "RM-5 Parked idea",         // Other
        ])
    }

    func testAGroupWithNoIssuesHasNoHeader() {
        let rig = makeRig(seed: { seedJira($0, [
            issue("RM-1", "Only one", category: "to_do"),
            issue("RM-2", "Another", status: "Done", category: "other"),
        ]) })

        XCTAssertTrue(waitUntil { rig.surface.rowTexts.count == 2 })
        XCTAssertEqual(rig.surface.groupHeaderTexts, ["To Do", "Other"])
    }

    func testAnIssueWithAnUnknownStatusCategoryLandsInOther() {
        let rig = makeRig(seed: { seedJira($0, [
            issue("RM-1", "Mystery", status: "Weird", category: "brand_new_category"),
            issue("RM-2", "No category", status: "Weird", category: nil),
        ]) })

        XCTAssertTrue(waitUntil { rig.surface.rowTexts.count == 2 })
        XCTAssertEqual(rig.surface.groupHeaderTexts, ["Other"])
    }

    func testRowsShowTheKeyPriorityAndStatusInTheList() {
        let rig = makeRig(seed: { seedJira($0, [
            issue("RM-12", "Summary", status: "In Review", category: "in_progress", priority: ("High", 2),
                  updated: "2026-10-06T15:00:00Z"),
        ]) })

        XCTAssertTrue(waitUntil { rig.surface.rowTexts.count == 1 })
        let row = rig.surface.rowTexts[0]
        XCTAssertEqual(row.title, "RM-12 Summary")
        XCTAssertEqual(row.priorityText, "High")
        XCTAssertEqual(row.statusText, "In Review")
        XCTAssertTrue(row.dueText?.hasPrefix("updated ") ?? false, String(describing: row.dueText))
    }

    func testIssuesArrivingAfterTheSurfaceExistsAreShownAndCounted() {
        let rig = makeRig()
        XCTAssertTrue(rig.surface.rowTexts.isEmpty)

        seedJira(rig.store, mixedIssues())

        XCTAssertTrue(waitUntil { rig.surface.rowTexts.count == 5 })
        XCTAssertTrue(waitUntil { rig.surface.tabButtonTitle(.jira) == "Jira 5" }, rig.surface.tabButtonTitle(.jira))
    }

    // MARK: Filters

    private func projectIssues() -> [WorkItem] {
        [
            issue("RM-1", "Fix the webhook", project: "RM", status: "In Progress", category: "in_progress",
                  priority: ("High", 2), updated: "2026-10-05T10:00:00Z"),
            issue("RM-2", "Write the docs", project: "RM", status: "To Do", category: "to_do",
                  priority: ("Low", 4), updated: "2026-10-04T10:00:00Z"),
            issue("OPS-3", "Rotate the webhook secret", project: "OPS", status: "In Progress", category: "in_progress",
                  priority: ("Medium", 3), updated: "2026-10-03T10:00:00Z"),
            issue("OPS-4", "Patch the bastion", project: "OPS", status: "Blocked", category: "to_do",
                  priority: ("Medium", 3), updated: "2026-10-02T10:00:00Z"),
        ]
    }

    private func menu(_ rig: Rig, _ facet: String) -> NSPopUpButton? {
        rigAllSubviews(of: rig.surface).compactMap { $0 as? NSPopUpButton }
            .first { $0.accessibilityLabel() == "Filter by \(facet)" }
    }

    /// Choose the menu entry for `value` (entries read "RM (2)") the way a click would.
    private func choose(_ value: String, in facet: String, _ rig: Rig,
                        file: StaticString = #filePath, line: UInt = #line) {
        let found = waitUntil {
            self.menu(rig, facet)?.menu?.items.contains { $0.title.hasPrefix("\(value) (") } ?? false
        }
        guard found, let item = menu(rig, facet)?.menu?.items.first(where: { $0.title.hasPrefix("\(value) (") }),
              let action = item.action else {
            XCTFail("no \"\(value)\" entry in the \(facet) menu: \(String(describing: menu(rig, facet)?.menu?.items.map(\.title)))",
                    file: file, line: line)
            return
        }
        XCTAssertTrue(NSApp.sendAction(action, to: item.target, from: item), file: file, line: line)
    }

    private func search(_ text: String, _ rig: Rig) {
        guard let field = rigAllSubviews(of: rig.surface).compactMap({ $0 as? NSSearchField }).first else {
            return XCTFail("no search field")
        }
        field.stringValue = text
        field.sendAction(field.action, to: field.target)
    }

    func testTheProjectAndStatusMenusOfferTheValuesPresentWithTheirCounts() {
        let rig = makeRig(seed: { seedJira($0, self.projectIssues()) })

        XCTAssertTrue(waitUntil { self.menu(rig, "project")?.menu?.items.count ?? 0 > 1 })
        let projects = menu(rig, "project")?.menu?.items.map(\.title) ?? []
        XCTAssertTrue(projects.contains("OPS (2)"), "\(projects)")
        XCTAssertTrue(projects.contains("RM (2)"), "\(projects)")
        XCTAssertTrue(waitUntil { self.menu(rig, "status")?.menu?.items.count ?? 0 > 1 })
        let statuses = menu(rig, "status")?.menu?.items.map(\.title) ?? []
        XCTAssertTrue(statuses.contains("In Progress (2)"), "\(statuses)")
        XCTAssertTrue(statuses.contains("Blocked (1)"), "\(statuses)")
    }

    func testChoosingAProjectNarrowsTheListToThatProject() {
        let rig = makeRig(seed: { seedJira($0, self.projectIssues()) })
        XCTAssertTrue(waitUntil { rig.surface.rowTexts.count == 4 })

        choose("OPS", in: "project", rig)

        expectRows(rig, ["OPS-3 Rotate the webhook secret", "OPS-4 Patch the bastion"])
    }

    func testChoosingTwoProjectsShowsBothAndChoosingAgainClearsTheChoice() {
        let rig = makeRig(seed: { seedJira($0, self.projectIssues()) })
        XCTAssertTrue(waitUntil { rig.surface.rowTexts.count == 4 })

        choose("OPS", in: "project", rig)
        expectRows(rig, ["OPS-3 Rotate the webhook secret", "OPS-4 Patch the bastion"])
        choose("RM", in: "project", rig)
        _ = waitUntil { rig.surface.rowTexts.count == 4 }
        XCTAssertEqual(rig.surface.rowTexts.count, 4, "the menu is multi-select: both projects are shown")

        choose("OPS", in: "project", rig)
        expectRows(rig, ["RM-1 Fix the webhook", "RM-2 Write the docs"], "OPS toggled off leaves only RM")
    }

    func testChoosingAStatusNarrowsTheListToThatStatus() {
        let rig = makeRig(seed: { seedJira($0, self.projectIssues()) })
        XCTAssertTrue(waitUntil { rig.surface.rowTexts.count == 4 })

        choose("In Progress", in: "status", rig)

        expectRows(rig, ["RM-1 Fix the webhook", "OPS-3 Rotate the webhook secret"])
    }

    func testProjectAndStatusFiltersCombine() {
        let rig = makeRig(seed: { seedJira($0, self.projectIssues()) })
        XCTAssertTrue(waitUntil { rig.surface.rowTexts.count == 4 })

        choose("OPS", in: "project", rig)
        expectRows(rig, ["OPS-3 Rotate the webhook secret", "OPS-4 Patch the bastion"])
        choose("Blocked", in: "status", rig)

        expectRows(rig, ["OPS-4 Patch the bastion"])
    }

    func testSearchNarrowsTheListBySummaryText() {
        let rig = makeRig(seed: { seedJira($0, self.projectIssues()) })
        XCTAssertTrue(waitUntil { rig.surface.rowTexts.count == 4 })

        search("webhook", rig)

        expectRows(rig, ["RM-1 Fix the webhook", "OPS-3 Rotate the webhook secret"])
    }

    func testSearchMatchesTheIssueKey() {
        let rig = makeRig(seed: { seedJira($0, self.projectIssues()) })
        XCTAssertTrue(waitUntil { rig.surface.rowTexts.count == 4 })

        search("ops-4", rig)

        expectRows(rig, ["OPS-4 Patch the bastion"], "search is case-insensitive and covers \"KEY summary\"")
    }

    func testSearchAndAProjectFilterBothApply() {
        let rig = makeRig(seed: { seedJira($0, self.projectIssues()) })
        XCTAssertTrue(waitUntil { rig.surface.rowTexts.count == 4 })

        choose("OPS", in: "project", rig)
        expectRows(rig, ["OPS-3 Rotate the webhook secret", "OPS-4 Patch the bastion"])
        search("webhook", rig)

        expectRows(rig, ["OPS-3 Rotate the webhook secret"])
    }

    func testClearingTheSearchBringsEveryIssueBack() {
        let rig = makeRig(seed: { seedJira($0, self.projectIssues()) })
        XCTAssertTrue(waitUntil { rig.surface.rowTexts.count == 4 })
        search("bastion", rig)
        expectRows(rig, ["OPS-4 Patch the bastion"])

        search("", rig)

        XCTAssertTrue(waitUntil { rig.surface.rowTexts.count == 4 })
    }

    // MARK: Source states

    private func visibleBanner(_ rig: Rig) -> SourceStateBanner? {
        rigAllSubviews(of: rig.surface).compactMap { $0 as? SourceStateBanner }
            .first { !$0.isHidden && $0.content != SourceStateBanner.disconnectedContent }
    }

    private func retryButton(in banner: SourceStateBanner) -> NSButton? {
        rigAllSubviews(of: banner).compactMap { $0 as? NSButton }.first { $0.title == "Retry" }
    }

    /// A sentinel standing in for a secret value: it lives in an unrelated field
    /// and must never reach a banner.
    private let secretSentinel = "SENTINEL-s3cr3t-token-value-91ac"

    func testUnauthenticatedShowsTheSourcesReasonNamingTheTokenVariableAndNeverAValue() throws {
        let reason = "Jira rejected the credentials (401). Check ATLASSIAN_API_TOKEN."
        let rig = makeRig(seed: {
            seedJira($0, [issue("RM-1", "Unrelated", searchExtra: " \(self.secretSentinel)")],
                     state: .unauthenticated, reason: reason)
        })

        let message = try XCTUnwrap(rig.surface.visibleBannerMessage)
        XCTAssertTrue(message.contains("ATLASSIAN_API_TOKEN"), message)
        XCTAssertTrue(message.contains(reason), "the banner repeats the source's reason: \(message)")
        XCTAssertFalse(message.contains(secretSentinel), "a credential value must never be shown: \(message)")
        XCTAssertFalse(rig.surface.tabButtonTitle(.jira).contains(secretSentinel))
        XCTAssertTrue(rig.surface.tabButtonTitle(.jira).contains("Sign in"), rig.surface.tabButtonTitle(.jira))
    }

    func testNotConfiguredSaysNoCredentialsWereFound() throws {
        let reason = "no credentials found. Set ATLASSIAN_SITE, ATLASSIAN_EMAIL and ATLASSIAN_API_TOKEN."
        let rig = makeRig(seed: { seedJira($0, [], state: .notConfigured, reason: reason) })

        let message = try XCTUnwrap(rig.surface.visibleBannerMessage)
        XCTAssertTrue(message.hasPrefix("Jira: no credentials found."), message)
        XCTAssertTrue(rig.surface.rowTexts.isEmpty)
        XCTAssertNil(rig.surface.emptyMessage, "an unconfigured source is not an empty list")
    }

    func testRateLimitedSaysWhenJiraWillBeRetriedAndKeepsTheIssuesVisible() throws {
        let retryAt = iso.date(from: "2026-10-09T15:42:00Z")!
        let rig = makeRig(seed: { seedJira($0, self.projectIssues(), state: .rateLimited, retryAt: retryAt) })

        XCTAssertTrue(waitUntil { rig.surface.rowTexts.count == 4 }, "items stay visible while rate-limited")
        let message = try XCTUnwrap(rig.surface.visibleBannerMessage)
        let clock = DateFormatter()
        clock.dateFormat = "h:mm a"
        XCTAssertEqual(message, "Rate-limited by Jira; retrying at \(clock.string(from: retryAt))")
    }

    func testRateLimitedWithoutARetryTimeStillSaysSo() throws {
        let rig = makeRig(seed: { seedJira($0, self.projectIssues(), state: .rateLimited) })

        let message = try XCTUnwrap(rig.surface.visibleBannerMessage)
        XCTAssertTrue(message.hasPrefix("Rate-limited by Jira"), message)
    }

    func testStaleShowsAStaleBannerWithRetryAndKeepsTheIssuesVisible() throws {
        let rig = makeRig(seed: { seedJira($0, self.projectIssues(), state: .stale, reason: "Jira unreachable") })

        XCTAssertTrue(waitUntil { rig.surface.rowTexts.count == 4 }, "items stay visible while stale")
        let message = try XCTUnwrap(rig.surface.visibleBannerMessage)
        XCTAssertTrue(message.hasPrefix("Stale"), message)
        XCTAssertTrue(message.contains("Jira unreachable"), message)
        let banner = try XCTUnwrap(visibleBanner(rig))
        XCTAssertEqual(banner.content?.showsRetry, true)
        let retry = try XCTUnwrap(retryButton(in: banner))
        XCTAssertFalse(retry.isHidden, "a stale source offers Retry")
    }

    func testPressingRetryOnAStaleBannerAsksTheDaemonToRefreshJira() throws {
        let rig = makeRig(seed: { seedJira($0, self.projectIssues(), state: .stale, reason: "Jira unreachable") })
        let retry = try XCTUnwrap(retryButton(in: try XCTUnwrap(visibleBanner(rig))))
        rig.log.frames.removeAll()

        retry.performClick(nil)

        XCTAssertEqual(rig.log.frames, [.refresh(source: .jira, fred: false)])
    }

    func testAFreshSourceShowsNoBanner() {
        let rig = makeRig(seed: { seedJira($0, self.projectIssues()) })

        XCTAssertTrue(waitUntil { rig.surface.rowTexts.count == 4 })
        XCTAssertNil(rig.surface.visibleBannerMessage)
        XCTAssertNil(rig.surface.emptyMessage)
    }

    func testAHealthyJiraWithNothingAssignedSaysSoPositively() {
        let rig = makeRig(seed: { seedJira($0, [], state: .empty) })

        XCTAssertNil(rig.surface.visibleBannerMessage)
        XCTAssertTrue(rig.surface.emptyMessage?.contains("Jira") ?? false, String(describing: rig.surface.emptyMessage))
        XCTAssertTrue(rig.surface.rowTexts.isEmpty)
    }
}
