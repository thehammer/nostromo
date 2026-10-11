import XCTest
import AppKit

// Slice T3: the Sentry tab. Issues are listed by when they were last seen, each
// row says how loud the issue is, and issues that appeared since the user last
// looked at the tab are marked "new". Everything is headless: a real
// `TeriSurfaceView` in an offscreen window, a fake clock and isolated
// UserDefaults suites. Nothing asserts on pixels or waits a fixed time; state
// changes are polled for on the run loop.

// MARK: - Helpers

@discardableResult
private func waitUntil(_ timeout: TimeInterval = 5, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { return false }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return true
}

private final class FakeClock {
    var now: Date
    init(_ now: Date) { self.now = now }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

/// "Now" for the pure row-content tests. Friday 9 October 2026, mid-afternoon UTC.
private let fixedNow = ISO8601DateFormatter().date(from: "2026-10-09T15:00:00Z")!

/// One Sentry issue as the daemon would send it. `lastSeen` is the wire `updated_at`.
private func issue(_ n: Int,
                   _ title: String = "TypeError in FacesheetParser",
                   level: String? = "error",
                   rank: Int? = 2,
                   project: String? = "portal-production",
                   environment: String? = "production",
                   events: Int? = 312,
                   users: Int? = 41,
                   createdAt: Date? = nil,
                   lastSeen: Date? = nil) -> WorkItem {
    var f: [String: Any] = [
        "id": "sentry:\(n)", "source": "sentry", "kind": "issue", "title": title,
        "search_text": title,
    ]
    if let level { f["severity"] = level }
    if let rank { f["priority"] = ["label": "P\(rank)", "rank": rank] }
    if let project { f["project"] = project }
    if let environment { f["environment"] = environment }
    var metrics: [String: Int] = [:]
    if let events { metrics["events_24h"] = events }
    if let users { metrics["users"] = users }
    f["metrics"] = metrics
    if let createdAt { f["created_at"] = iso(createdAt) }
    if let lastSeen { f["updated_at"] = iso(lastSeen) }
    return WorkTestSupport.makeItem(f)
}

private var suites: [String] = []

private func makeDefaults() -> UserDefaults {
    let name = "nostromo.tests.teriSentry.\(UUID().uuidString)"
    suites.append(name)
    return UserDefaults(suiteName: name)!
}

private func removeSuites() {
    for name in suites { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
    suites.removeAll()
}

// MARK: - Row content (pure)

final class TeriSentryRowContentTests: XCTestCase {
    private var savedTracker: TeriSentryViewTracker!

    override func setUp() {
        super.setUp()
        savedTracker = TeriSentryTab.tracker
        // Never viewed before: nothing is "new" unless a test says so.
        TeriSentryTab.tracker = TeriSentryViewTracker(defaults: makeDefaults(), now: { fixedNow })
    }

    override func tearDown() {
        TeriSentryTab.tracker = savedTracker
        removeSuites()
        super.tearDown()
    }

    private func content(_ item: WorkItem) -> WorkRowContent {
        TeriSentryTab.rowContent(for: item, now: fixedNow)
    }

    private func minutesAgo(_ m: Double) -> Date { fixedNow.addingTimeInterval(-m * 60) }

    func testTheConfigDescribesTheSentryTab() {
        let config = TeriSentryTab.config
        XCTAssertEqual(config.tab, .sentry)
        XCTAssertEqual(config.sourceName, "Sentry")
        XCTAssertEqual(config.list?.menuFacets, [.project],
                       "Sentry's list endpoint returns no environments, so there is nothing to filter by")
        XCTAssertEqual(config.rowRefreshInterval, 60, "relative times are re-rendered every minute")
        XCTAssertEqual(config.list?.searchPlaceholder, "Filter issues")
        XCTAssertNotNil(config.onShow)
        XCTAssertNotNil(config.onLeave)
    }

    func testTheLevelIsShownAsUppercaseTextAndTheRankColoursIt() {
        XCTAssertEqual(content(issue(1, level: "fatal", rank: 1)).priorityText, "FATAL")
        XCTAssertEqual(content(issue(1, level: "error", rank: 2)).priorityText, "ERROR")
        XCTAssertEqual(content(issue(1, level: "warning", rank: 3)).priorityText, "WARNING")
        XCTAssertEqual(content(issue(1, level: "fatal", rank: 1)).priorityRank, 1)
        XCTAssertEqual(content(issue(1, level: "warning", rank: 3)).priorityRank, 3)
        XCTAssertNil(content(issue(1, rank: nil)).priorityRank)
    }

    func testTheTitleIsShownVerbatim() {
        XCTAssertEqual(content(issue(1, "KeyError: 'résumé' in ingest")).title, "KeyError: 'résumé' in ingest")
    }

    func testTheSecondLineGivesEventsUsersAndWhenItWasLastSeen() {
        let c = content(issue(1, events: 312, users: 41, lastSeen: minutesAgo(4)))
        XCTAssertEqual(c.dueText, "312 events / 24 h · 41 users · last seen 4 min ago")
    }

    func testOneEventAndOneUserAreSingular() {
        let c = content(issue(1, events: 1, users: 1, lastSeen: minutesAgo(4)))
        XCTAssertEqual(c.dueText, "1 event / 24 h · 1 user · last seen 4 min ago")
    }

    func testLastSeenIsRelativeToNow() {
        func text(_ ago: TimeInterval) -> String? {
            content(issue(1, events: nil, users: nil, lastSeen: fixedNow.addingTimeInterval(-ago))).dueText
        }
        XCTAssertEqual(text(30), "last seen just now")
        XCTAssertEqual(text(4 * 60), "last seen 4 min ago")
        XCTAssertEqual(text(3 * 3600), "last seen 3 h ago")
        XCTAssertEqual(text(2 * 86_400), "last seen 2 d ago")
    }

    func testAPartWithNoDataIsLeftOutRatherThanShownAsZero() {
        XCTAssertEqual(content(issue(1, events: nil, users: 41, lastSeen: minutesAgo(4))).dueText,
                       "41 users · last seen 4 min ago")
        XCTAssertEqual(content(issue(1, events: 312, users: nil, lastSeen: minutesAgo(4))).dueText,
                       "312 events / 24 h · last seen 4 min ago")
        XCTAssertEqual(content(issue(1, events: 312, users: 41, lastSeen: nil)).dueText,
                       "312 events / 24 h · 41 users")
        XCTAssertEqual(content(issue(1, events: nil, users: nil, lastSeen: minutesAgo(4))).dueText,
                       "last seen 4 min ago")
        let bare = content(issue(1, events: nil, users: nil, lastSeen: nil)).dueText
        XCTAssertTrue(bare == nil || bare == "", "nothing to say: \(String(describing: bare))")
    }

    func testTheStatusColumnNeverShowsAnEnvironmentEvenWhenTheItemCarriesOne() {
        XCTAssertNil(content(issue(1, environment: "production")).statusText)
        XCTAssertNil(content(issue(1, environment: "staging")).statusText)
        XCTAssertNil(content(issue(1, environment: nil)).statusText)
    }

    func testTheAccessibilityLabelNamesProjectTitleEventsAndLastSeen() {
        let item = issue(1, "TypeError in FacesheetParser", project: "portal-production",
                         events: 312, users: 41, lastSeen: minutesAgo(4))
        XCTAssertEqual(content(item).accessibilityLabel,
                       "Sentry issue, portal-production, TypeError in FacesheetParser, 312 events, last seen 4 minutes ago")
    }

    func testTheAccessibilityLabelSpellsOutUnitsAndUsesSingularsAtOne() {
        func label(events: Int?, ago: TimeInterval) -> String {
            content(issue(1, events: events, lastSeen: fixedNow.addingTimeInterval(-ago))).accessibilityLabel
        }
        XCTAssertTrue(label(events: 1, ago: 60).hasSuffix("1 event, last seen 1 minute ago"), label(events: 1, ago: 60))
        XCTAssertTrue(label(events: 5, ago: 3 * 3600).hasSuffix("5 events, last seen 3 hours ago"))
        XCTAssertTrue(label(events: 5, ago: 3600).hasSuffix("last seen 1 hour ago"))
        XCTAssertTrue(label(events: 5, ago: 2 * 86_400).hasSuffix("last seen 2 days ago"))
        XCTAssertTrue(label(events: 5, ago: 86_400).hasSuffix("last seen 1 day ago"))
    }

    func testTheAccessibilityLabelOmitsWhatIsMissing() {
        let noProject = content(issue(1, "Boom", project: nil, events: 7, lastSeen: minutesAgo(2))).accessibilityLabel
        XCTAssertEqual(noProject, "Sentry issue, Boom, 7 events, last seen 2 minutes ago")

        let bare = content(issue(1, "Boom", project: nil, events: nil, lastSeen: nil)).accessibilityLabel
        XCTAssertEqual(bare, "Sentry issue, Boom")
    }

    // MARK: "new"

    private func trackerWithLastView(at lastView: Date) -> TeriSentryViewTracker {
        let defaults = makeDefaults()
        defaults.set(lastView, forKey: TeriSentryViewTracker.lastViewedKey)
        let tracker = TeriSentryViewTracker(defaults: defaults, now: { fixedNow })
        tracker.didShow()
        return tracker
    }

    func testAnIssueCreatedSinceTheLastViewIsMarkedNewInTextAndForVoiceOver() {
        TeriSentryTab.tracker = trackerWithLastView(at: minutesAgo(60))
        let item = issue(1, "TypeError in FacesheetParser", project: "portal-production", environment: "production",
                         events: 312, createdAt: minutesAgo(10), lastSeen: minutesAgo(4))

        let c = content(item)

        XCTAssertEqual(c.statusText, "new", "the marker stands alone: no environment beside it")
        XCTAssertEqual(c.accessibilityLabel,
                       "Sentry issue, portal-production, TypeError in FacesheetParser, 312 events, last seen 4 minutes ago, new")
    }

    func testAnIssueOlderThanTheLastViewIsNotMarkedNew() {
        TeriSentryTab.tracker = trackerWithLastView(at: minutesAgo(60))
        let c = content(issue(1, environment: "production", createdAt: minutesAgo(120), lastSeen: minutesAgo(4)))

        XCTAssertNil(c.statusText)
        XCTAssertFalse(c.accessibilityLabel.hasSuffix(", new"), c.accessibilityLabel)
    }

    func testANewIssueIsJustMarkedNewWhateverItsEnvironment() {
        TeriSentryTab.tracker = trackerWithLastView(at: minutesAgo(60))
        XCTAssertEqual(content(issue(1, environment: nil, createdAt: minutesAgo(10))).statusText, "new")
        XCTAssertEqual(content(issue(1, environment: "staging", createdAt: minutesAgo(10))).statusText, "new")
    }
}

// MARK: - New-since-last-view tracking

final class TeriSentryViewTrackerTests: XCTestCase {
    private let t0 = ISO8601DateFormatter().date(from: "2026-10-09T09:00:00Z")!

    override func tearDown() {
        removeSuites()
        super.tearDown()
    }

    private func tracker(_ defaults: UserDefaults, _ clock: FakeClock) -> TeriSentryViewTracker {
        TeriSentryViewTracker(defaults: defaults, now: { clock.now })
    }

    func testTheFirstEverViewMarksNothingNew() {
        let clock = FakeClock(t0)
        let tracker = tracker(makeDefaults(), clock)

        tracker.didShow()

        XCTAssertNil(tracker.baseline, "never viewed before")
        XCTAssertFalse(tracker.isNew(issue(1, createdAt: t0.addingTimeInterval(-86_400))))
        XCTAssertFalse(tracker.isNew(issue(2, createdAt: t0)))
    }

    func testBeforeAnyViewNothingIsNew() {
        let tracker = tracker(makeDefaults(), FakeClock(t0))
        XCTAssertFalse(tracker.isNew(issue(1, createdAt: t0)))
    }

    func testAnIssueCreatedWhileTheUserWasAwayIsNewOnReturn() {
        let clock = FakeClock(t0)
        let tracker = tracker(makeDefaults(), clock)
        tracker.didShow()
        clock.advance(300)
        tracker.didLeave()                    // left at t0 + 5 min
        let leftAt = clock.now

        clock.advance(3600)
        let whileAway = issue(1, createdAt: leftAt.addingTimeInterval(600))
        tracker.didShow()

        XCTAssertEqual(tracker.baseline, leftAt)
        XCTAssertTrue(tracker.isNew(whileAway))
    }

    func testAnIssueOlderThanTheLastViewIsNotNewOnReturn() {
        let clock = FakeClock(t0)
        let tracker = tracker(makeDefaults(), clock)
        tracker.didShow()
        clock.advance(300)
        tracker.didLeave()
        let leftAt = clock.now

        clock.advance(3600)
        tracker.didShow()

        XCTAssertFalse(tracker.isNew(issue(1, createdAt: leftAt.addingTimeInterval(-60))))
        XCTAssertFalse(tracker.isNew(issue(2, createdAt: leftAt)), "created exactly at the last view is not after it")
    }

    func testAnIssueWithNoCreationTimeIsNeverNew() {
        let clock = FakeClock(t0)
        let tracker = tracker(makeDefaults(), clock)
        tracker.didShow(); clock.advance(60); tracker.didLeave(); clock.advance(60); tracker.didShow()

        XCTAssertFalse(tracker.isNew(issue(1, createdAt: nil)))
    }

    func testAnIssueArrivingWhileTheTabIsOpenIsNew() {
        let clock = FakeClock(t0)
        let tracker = tracker(makeDefaults(), clock)
        tracker.didShow(); clock.advance(60); tracker.didLeave()
        let leftAt = clock.now

        clock.advance(600)
        tracker.didShow()
        clock.advance(120)                    // two minutes into this view
        let arrived = issue(1, createdAt: clock.now)

        XCTAssertTrue(tracker.isNew(arrived), "still compared with the previous view, not this one")
        XCTAssertEqual(tracker.baseline, leftAt)
    }

    func testLeavingDoesNotChangeWhatIsNewUntilTheNextShow() {
        let clock = FakeClock(t0)
        let tracker = tracker(makeDefaults(), clock)
        tracker.didShow(); clock.advance(60); tracker.didLeave()
        let firstLeave = clock.now
        clock.advance(600)
        tracker.didShow()
        let arrived = issue(1, createdAt: clock.now.addingTimeInterval(30))
        clock.advance(120)

        tracker.didLeave()

        XCTAssertEqual(tracker.baseline, firstLeave, "the rows on screen keep their markers while the user leaves")
        XCTAssertTrue(tracker.isNew(arrived))

        clock.advance(600)
        tracker.didShow()
        XCTAssertFalse(tracker.isNew(arrived), "seen during the last view, so no longer new")
    }

    func testLastViewedSurvivesARelaunch() {
        let defaults = makeDefaults()
        let clock = FakeClock(t0)
        let first = tracker(defaults, clock)
        first.didShow(); clock.advance(300); first.didLeave()
        let leftAt = clock.now

        clock.advance(86_400)                 // "relaunch": a brand new tracker on the same defaults
        let second = tracker(defaults, clock)
        second.didShow()

        XCTAssertEqual(second.baseline, leftAt)
        XCTAssertEqual(defaults.object(forKey: TeriSentryViewTracker.lastViewedKey) as? Date, clock.now,
                       "showing records the new last-viewed time")
    }

    func testTheLastViewedTimeIsStoredUnderThePublishedKey() {
        XCTAssertEqual(TeriSentryViewTracker.lastViewedKey, "nostromo.teri.sentryLastViewed")
        let defaults = makeDefaults()
        let clock = FakeClock(t0)
        let tracker = tracker(defaults, clock)

        tracker.didShow()
        XCTAssertEqual(defaults.object(forKey: TeriSentryViewTracker.lastViewedKey) as? Date, t0)

        clock.advance(90)
        tracker.didLeave()
        XCTAssertEqual(defaults.object(forKey: TeriSentryViewTracker.lastViewedKey) as? Date, t0.addingTimeInterval(90))
    }
}

// MARK: - The real surface

final class TeriSentryTabSurfaceTests: XCTestCase {
    private var savedTracker: TeriSentryViewTracker!
    private let clock = FakeClock(ISO8601DateFormatter().date(from: "2026-10-09T09:00:00Z")!)
    private var trackerDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        savedTracker = TeriSentryTab.tracker
        trackerDefaults = makeDefaults()
        let clock = self.clock
        TeriSentryTab.tracker = TeriSentryViewTracker(defaults: trackerDefaults, now: { clock.now })
    }

    override func tearDown() {
        TeriSentryTab.tracker = savedTracker
        removeSuites()
        super.tearDown()
    }

    private struct Rig {
        let store: WorkStore
        let window: RigWindow
        let surface: TeriSurfaceView
    }

    private func makeRig(defaults: UserDefaults? = nil, seed: (WorkStore) -> Void = { _ in }) -> Rig {
        let store = WorkStore()
        store.sendFrame = { _ in }
        seed(store)
        let window = makeRigWindow(self, size: NSSize(width: 900, height: 700))
        let surface = TeriSurfaceView(store: store, defaults: defaults ?? makeDefaults(),
                                      center: NotificationCenter(), scheduler: .main)
        surface.frame = window.contentView!.bounds
        surface.autoresizingMask = [.width, .height]
        window.contentView!.addSubview(surface)
        surface.layoutSubtreeIfNeeded()
        return Rig(store: store, window: window, surface: surface)
    }

    private func lastViewed() -> Date? {
        trackerDefaults.object(forKey: TeriSentryViewTracker.lastViewedKey) as? Date
    }

    // MARK: Ordering

    func testIssuesAreListedByWhenTheyWereLastSeenNewestFirst() {
        let base = clock.now
        let rig = makeRig(seed: { store in
            store.apply(snapshot: .sentry, group: nil, items: [
                issue(1, "Seen an hour ago", lastSeen: base.addingTimeInterval(-3600)),
                issue(2, "Seen a minute ago", lastSeen: base.addingTimeInterval(-60)),
                issue(3, "Seen yesterday", lastSeen: base.addingTimeInterval(-86_400)),
                issue(4, "Seen ten minutes ago", lastSeen: base.addingTimeInterval(-600)),
            ])
            store.apply(status: SourceStatus(source: .sentry, state: .fresh, count: 4))
        })
        rig.surface.select(.sentry)

        XCTAssertTrue(waitUntil { rig.surface.rowTexts.count == 4 })
        XCTAssertEqual(rig.surface.rowTexts.map(\.title),
                       ["Seen a minute ago", "Seen ten minutes ago", "Seen an hour ago", "Seen yesterday"])
    }

    func testARowShowsTheLevelAndEventsThroughTheRealSurfaceWithoutAnEnvironment() {
        let now = Date()
        let rig = makeRig(seed: { store in
            store.apply(snapshot: .sentry, group: nil, items: [
                issue(1, "Fatal one", level: "fatal", rank: 1, environment: "production", events: 9, users: 2,
                      createdAt: now.addingTimeInterval(-86_400), lastSeen: now.addingTimeInterval(-120)),
            ])
            store.apply(status: SourceStatus(source: .sentry, state: .fresh, count: 1))
        })
        rig.surface.select(.sentry)

        XCTAssertTrue(waitUntil { rig.surface.rowTexts.count == 1 })
        let row = rig.surface.rowTexts[0]
        XCTAssertEqual(row.priorityText, "FATAL")
        XCTAssertEqual(row.title, "Fatal one")
        XCTAssertNil(row.statusText, "not new, and Sentry rows never show an environment")
        XCTAssertTrue(row.dueText?.hasPrefix("9 events / 24 h · 2 users · last seen ") ?? false,
                      String(describing: row.dueText))
        XCTAssertTrue(row.accessibilityLabel.hasPrefix("Sentry issue, portal-production, Fatal one, 9 events"),
                      row.accessibilityLabel)
    }

    // MARK: Filters

    private func fixtureItems() -> [WorkItem] {
        let base = clock.now
        return [
            issue(1, "A", project: "portal-production", environment: "production", lastSeen: base.addingTimeInterval(-10)),
            issue(2, "B", project: "portal-production", environment: "staging", lastSeen: base.addingTimeInterval(-20)),
            issue(3, "C", project: "payments-production", environment: "production", lastSeen: base.addingTimeInterval(-30)),
            issue(4, "D", project: "payments-production", environment: "production", lastSeen: base.addingTimeInterval(-40)),
            issue(5, "E", project: nil, environment: nil, lastSeen: base.addingTimeInterval(-50)),
        ]
    }

    private func snapshot(_ filter: WorkFilter) -> WorkListSnapshot {
        let store = WorkStore()
        store.apply(snapshot: .sentry, group: nil, items: fixtureItems())
        var result: WorkListSnapshot?
        store.computeListSnapshot(source: .sentry, filter: filter, sort: .newest,
                                  facets: TeriSentryTab.config.list?.facets ?? []) { result = $0 }
        XCTAssertTrue(waitUntil { result != nil })
        return result!
    }

    private func titles(_ s: WorkListSnapshot) -> [String] { s.groups.flatMap { $0.items.map(\.title) } }

    func testFilteringByProjectKeepsOnlyThatProjectsIssues() {
        var f = WorkFilter(); f.projects = ["payments-production"]
        XCTAssertEqual(titles(snapshot(f)), ["C", "D"])
    }

    func testTheOnlyFilterMenuIsTheProjectMenuWithCounts() {
        XCTAssertEqual(TeriSentryTab.config.list?.facets, [.project])
        let s = snapshot(WorkFilter())
        XCTAssertEqual(s.facetCounts[.project], ["portal-production": 2, "payments-production": 2])
        XCTAssertTrue((s.facetCounts[.environment] ?? [:]).isEmpty, "no Environment menu is offered, so none is counted")
    }

    func testAProjectFilterCountsIgnoreItsOwnSelection() {
        var f = WorkFilter(); f.projects = ["payments-production"]
        let s = snapshot(f)
        XCTAssertEqual(s.facetCounts[.project], ["portal-production": 2, "payments-production": 2],
                       "project counts ignore the project filter itself")
    }

    // MARK: Source states

    private func bannerRig(_ state: SourceState, reason: String? = nil, withItems: Bool = false) -> Rig {
        let base = clock.now
        let rig = makeRig(seed: { store in
            if withItems {
                store.apply(snapshot: .sentry, group: nil, items: [issue(1, lastSeen: base.addingTimeInterval(-60))])
            }
            store.apply(status: SourceStatus(source: .sentry, state: state, reason: reason, count: withItems ? 1 : 0))
        })
        rig.surface.select(.sentry)
        rig.surface.layoutSubtreeIfNeeded()
        return rig
    }

    func testEachSentryStateThatNeedsExplainingShowsItsOwnBannerNamingSentry() {
        let states: [SourceState] = [.unauthenticated, .rateLimited, .stale, .notConfigured, .error]
        var messages: [SourceState: String] = [:]
        for state in states {
            let rig = bannerRig(state, reason: "reason for \(state.rawValue)", withItems: state == .stale)
            guard let message = rig.surface.visibleBannerMessage else {
                XCTFail("no banner for \(state)"); continue
            }
            messages[state] = message
        }
        XCTAssertEqual(Set(messages.values).count, messages.count, "banners differ per state: \(messages)")
        for state in [SourceState.unauthenticated, .rateLimited, .notConfigured, .error] {
            XCTAssertTrue(messages[state]?.contains("Sentry") ?? false, "\(state): \(String(describing: messages[state]))")
        }
    }

    func testTheUnauthenticatedBannerRepeatsTheReason() {
        let rig = bannerRig(.unauthenticated, reason: "Sentry rejected the token (401)")
        XCTAssertTrue(rig.surface.visibleBannerMessage?.contains("Sentry rejected the token (401)") ?? false,
                      String(describing: rig.surface.visibleBannerMessage))
    }

    func testMissingCredentialsTellTheUserWhereToPutThem() {
        let reason = "Sentry: no credentials found. Set SENTRY_API_TOKEN in ~/.claude/credentials/.env, as the sentry skill uses."
        let rig = bannerRig(.notConfigured, reason: reason)

        let message = rig.surface.visibleBannerMessage ?? ""
        XCTAssertTrue(message.contains("SENTRY_API_TOKEN"), message)
        XCTAssertTrue(message.contains("~/.claude/credentials/.env"), message)
        XCTAssertTrue(rig.surface.rowTexts.isEmpty)
        XCTAssertNil(rig.surface.emptyMessage, "an unconfigured source must not look like a clean bill of health")
    }

    func testAStaleSentryKeepsItsIssuesAndSaysTheyAreStale() {
        let rig = bannerRig(.stale, reason: "network timeout", withItems: true)

        XCTAssertTrue(waitUntil { rig.surface.rowTexts.count == 1 })
        XCTAssertNotNil(rig.surface.visibleBannerMessage)
    }

    func testAHealthySentryWithNoIssuesSaysThereAreNone() {
        let rig = bannerRig(.empty)
        XCTAssertNil(rig.surface.visibleBannerMessage)
        XCTAssertFalse(rig.surface.emptyMessage?.isEmpty ?? true)
    }

    // MARK: Show / leave wiring

    func testSelectingTheSentryTabCountsAsViewingItAndLeavingItRecordsWhen() {
        let rig = makeRig()
        XCTAssertNil(lastViewed(), "the Todos tab is showing; Sentry has not been viewed")

        let shownAt = clock.now
        rig.surface.select(.sentry)
        XCTAssertEqual(lastViewed(), shownAt)

        clock.advance(120)
        rig.surface.select(.todos)
        XCTAssertEqual(lastViewed(), clock.now, "switching away is leaving")
        _ = rig
    }

    func testSwitchingBetweenOtherTabsDoesNotTouchTheSentryLastViewedTime() {
        let rig = makeRig()
        rig.surface.select(.jira)
        clock.advance(60)
        rig.surface.select(.repoDocs)
        clock.advance(60)
        rig.surface.select(.todos)

        XCTAssertNil(lastViewed())
        _ = rig
    }

    func testIssuesCreatedWhileOnAnotherTabAreNewWhenTheUserComesBack() {
        let rig = makeRig()
        rig.surface.select(.sentry)
        clock.advance(300)
        rig.surface.select(.todos)
        let leftAt = clock.now

        clock.advance(600)
        let arrived = issue(1, createdAt: leftAt.addingTimeInterval(120))
        let seenBefore = issue(2, createdAt: leftAt.addingTimeInterval(-120))
        rig.surface.select(.sentry)

        XCTAssertTrue(TeriSentryTab.tracker.isNew(arrived))
        XCTAssertFalse(TeriSentryTab.tracker.isNew(seenBefore))
        _ = rig
    }

    func testARestoredSentryTabCountsAsShownAtStartup() {
        let defaults = makeDefaults()
        var state = TeriViewState()
        state.selectedTab = .sentry
        state.save(to: defaults)

        let rig = makeRig(defaults: defaults)

        XCTAssertEqual(rig.surface.selectedTab, .sentry)
        XCTAssertEqual(lastViewed(), clock.now)
    }

    func testReselectingTheVisibleSentryTabIsNotALeaveAndReturn() {
        let rig = makeRig()
        rig.surface.select(.sentry)
        let shownAt = clock.now
        clock.advance(300)

        rig.surface.select(.sentry)

        XCTAssertEqual(lastViewed(), shownAt)
        _ = rig
    }

    func testTheSurfaceGoingAwayWhileOnTheSentryTabCountsAsLeaving() {
        let store = WorkStore()
        store.sendFrame = { _ in }
        let defaults = makeDefaults()
        var goneAt = clock.now
        autoreleasepool {
            // No window: nothing but the test holds the surface.
            let surface = TeriSurfaceView(store: store, defaults: defaults,
                                          center: NotificationCenter(), scheduler: .main)
            surface.select(.sentry)
            clock.advance(500)
            goneAt = clock.now
            XCTAssertNotNil(surface)
        }

        XCTAssertTrue(waitUntil(2) { self.lastViewed() == goneAt },
                      "deallocating the surface must record the leave: \(String(describing: lastViewed()))")
    }
}

// MARK: - Reference-counted view tracking (pure)

/// A second window, or a surface rebuilt while the first is still showing the
/// tab, must not wipe the "new" markers the first one is displaying, and one of
/// them going away must not count as the user leaving the tab.
final class TeriSentryTrackerReferenceCountTests: XCTestCase {
    private let t0 = ISO8601DateFormatter().date(from: "2026-10-09T09:00:00Z")!

    override func tearDown() {
        removeSuites()
        super.tearDown()
    }

    private func lastViewed(_ defaults: UserDefaults) -> Date? {
        defaults.object(forKey: TeriSentryViewTracker.lastViewedKey) as? Date
    }

    /// A tracker on defaults that already remember a view an hour before `t0`.
    private func trackerWithEarlierView(_ clock: FakeClock) -> (TeriSentryViewTracker, UserDefaults, Date) {
        let defaults = makeDefaults()
        let earlier = t0.addingTimeInterval(-3600)
        defaults.set(earlier, forKey: TeriSentryViewTracker.lastViewedKey)
        return (TeriSentryViewTracker(defaults: defaults, now: { clock.now }), defaults, earlier)
    }

    func testASecondShowWhileAlreadyShownChangesNeitherTheBaselineNorTheStoredTime() {
        let clock = FakeClock(t0)
        let (tracker, defaults, earlier) = trackerWithEarlierView(clock)
        tracker.didShow()
        let created = issue(1, createdAt: t0.addingTimeInterval(-600))
        XCTAssertTrue(tracker.isNew(created))

        clock.advance(300)
        tracker.didShow()

        XCTAssertEqual(tracker.baseline, earlier)
        XCTAssertEqual(lastViewed(defaults), t0, "still the time of the first show")
        XCTAssertTrue(tracker.isNew(created), "the marker survives the second show")
    }

    func testLeavingOneOfTwoShownSurfacesStoresNothing() {
        let clock = FakeClock(t0)
        let (tracker, defaults, _) = trackerWithEarlierView(clock)
        tracker.didShow()
        tracker.didShow()

        clock.advance(120)
        tracker.didLeave()

        XCTAssertEqual(lastViewed(defaults), t0, "one surface is still showing the tab")
    }

    func testLeavingTheLastShownSurfaceStoresTheLeaveTime() {
        let clock = FakeClock(t0)
        let (tracker, defaults, _) = trackerWithEarlierView(clock)
        tracker.didShow()
        tracker.didShow()
        clock.advance(120)
        tracker.didLeave()

        clock.advance(60)
        tracker.didLeave()

        XCTAssertEqual(lastViewed(defaults), t0.addingTimeInterval(180))
    }

    func testTheBaselineAfterAFullLeaveIsTheLeaveTime() {
        let clock = FakeClock(t0)
        let (tracker, _, _) = trackerWithEarlierView(clock)
        tracker.didShow()
        tracker.didShow()
        clock.advance(120)
        tracker.didLeave()
        tracker.didLeave()
        let leftAt = clock.now

        clock.advance(3600)
        tracker.didShow()

        XCTAssertEqual(tracker.baseline, leftAt)
    }

    func testShowingAgainWhileOneSurfaceStillShowsDoesNotMoveTheBaseline() {
        let clock = FakeClock(t0)
        let (tracker, defaults, earlier) = trackerWithEarlierView(clock)
        tracker.didShow()
        tracker.didShow()
        clock.advance(60)
        tracker.didLeave()          // one left

        clock.advance(60)
        tracker.didShow()           // a third arrives

        XCTAssertEqual(tracker.baseline, earlier)
        XCTAssertEqual(lastViewed(defaults), t0)
    }

    func testAnUnbalancedLeaveNeverDrivesTheCountBelowZero() {
        let clock = FakeClock(t0)
        let (tracker, defaults, _) = trackerWithEarlierView(clock)
        tracker.didLeave()          // never shown
        tracker.didLeave()

        tracker.didShow()
        let shownAt = clock.now
        tracker.didShow()
        clock.advance(120)
        tracker.didLeave()          // two shows, one leave: still showing

        XCTAssertEqual(lastViewed(defaults), shownAt,
                       "stray leaves must not leave the count negative and make this leave look final")
    }

    // MARK: Explicit "mark seen"

    func testMarkSeenMovesTheBaselineAndTheStoredTimeToNow() {
        let clock = FakeClock(t0)
        let (tracker, defaults, earlier) = trackerWithEarlierView(clock)
        tracker.didShow()
        let created = issue(1, createdAt: t0.addingTimeInterval(-600))
        XCTAssertEqual(tracker.baseline, earlier)
        XCTAssertTrue(tracker.isNew(created))

        clock.advance(120)
        tracker.markSeen()

        XCTAssertEqual(tracker.baseline, clock.now)
        XCTAssertEqual(lastViewed(defaults), clock.now)
        XCTAssertFalse(tracker.isNew(created))
        XCTAssertFalse(tracker.isNew(issue(2, createdAt: clock.now)), "created exactly now is not after the baseline")
    }

    func testAnIssueArrivingAfterMarkSeenIsNew() {
        let clock = FakeClock(t0)
        let (tracker, _, _) = trackerWithEarlierView(clock)
        tracker.didShow()
        clock.advance(120)
        tracker.markSeen()

        clock.advance(60)

        XCTAssertTrue(tracker.isNew(issue(1, createdAt: clock.now)))
    }

    func testMarkSeenDoesNotChangeHowManySurfacesAreShowing() {
        let clock = FakeClock(t0)
        let (tracker, defaults, _) = trackerWithEarlierView(clock)
        tracker.didShow()
        clock.advance(60)
        tracker.markSeen()

        clock.advance(60)
        tracker.didLeave()

        XCTAssertEqual(lastViewed(defaults), clock.now, "the one surface left, so the leave time is stored")
    }
}

// MARK: - Shared rig for the surface-level tests below

/// Isolated tracker defaults and a fake clock for both the tracker and the rows'
/// "last seen" text; the real ones are put back afterwards.
class TeriSentryClockedTestCase: XCTestCase {
    fileprivate let t0 = ISO8601DateFormatter().date(from: "2026-10-09T09:00:00Z")!
    fileprivate lazy var clock = FakeClock(t0)
    fileprivate var trackerDefaults: UserDefaults!
    private var savedTracker: TeriSentryViewTracker!
    private var savedNow: (() -> Date)!

    override func setUp() {
        super.setUp()
        savedTracker = TeriSentryTab.tracker
        savedNow = TeriSentryTab.now
        trackerDefaults = makeDefaults()
        let clock = self.clock
        TeriSentryTab.tracker = TeriSentryViewTracker(defaults: trackerDefaults, now: { clock.now })
        TeriSentryTab.now = { clock.now }
    }

    override func tearDown() {
        TeriSentryTab.tracker = savedTracker
        TeriSentryTab.now = savedNow
        removeSuites()
        super.tearDown()
    }

    fileprivate func lastViewed() -> Date? {
        trackerDefaults.object(forKey: TeriSentryViewTracker.lastViewedKey) as? Date
    }

    /// A surface in its own offscreen window that the test can let go of.
    fileprivate final class Holder {
        let window: RigWindow
        private(set) var surface: TeriSurfaceView?
        private weak var weakSurface: TeriSurfaceView?

        init(window: RigWindow, surface: TeriSurfaceView) {
            self.window = window
            self.surface = surface
            weakSurface = surface
        }

        var live: TeriSurfaceView { surface! }

        /// Drives the surface inside its own autorelease pool: AppKit autoreleases
        /// references to the surface while it works, and a test that then asserts
        /// the surface was deallocated would otherwise see it kept alive until the
        /// whole test method returns.
        func select(_ tab: TeriTab) {
            autoreleasepool { surface?.select(tab) }
        }
        var isGone: Bool { weakSurface == nil }

        func release() {
            autoreleasepool {
                surface?.removeFromSuperview()
                surface = nil
            }
        }
    }

    fileprivate func makeHolder(store: WorkStore, defaults: UserDefaults? = nil,
                                scheduler: WorkScheduler = .main) -> Holder {
        let window = makeRigWindow(self, size: NSSize(width: 900, height: 700))
        var surface: TeriSurfaceView!
        autoreleasepool {
            surface = TeriSurfaceView(store: store, defaults: defaults ?? makeDefaults(),
                                      center: NotificationCenter(), scheduler: scheduler)
            surface.frame = window.contentView!.bounds
            surface.autoresizingMask = [.width, .height]
            window.contentView!.addSubview(surface)
            surface.layoutSubtreeIfNeeded()
        }
        return Holder(window: window, surface: surface)
    }

    /// A store with the user's two Sentry issues. "Fresh" was created ten minutes
    /// before `t0` (after the last view an hour earlier); "Old" two hours before.
    fileprivate func makeStore(status: SourceStatus? = nil) -> WorkStore {
        let store = WorkStore()
        store.sendFrame = { _ in }
        store.apply(snapshot: .sentry, group: nil, items: [
            issue(1, "Fresh", createdAt: t0.addingTimeInterval(-600), lastSeen: t0.addingTimeInterval(-240)),
            issue(2, "Old", createdAt: t0.addingTimeInterval(-7200), lastSeen: t0.addingTimeInterval(-3600)),
        ])
        store.apply(status: status ?? SourceStatus(source: .sentry, state: .fresh, count: 2))
        return store
    }

    /// The user looked at the tab an hour before `t0`.
    fileprivate func rememberAnEarlierView() {
        trackerDefaults.set(t0.addingTimeInterval(-3600), forKey: TeriSentryViewTracker.lastViewedKey)
    }

    fileprivate func row(_ surface: TeriSurfaceView, _ title: String) -> WorkRowContent? {
        surface.rowTexts.first { $0.title == title }
    }
}

// MARK: - Two surfaces, one tracker

final class TeriSentryTwoSurfaceTests: TeriSentryClockedTestCase {
    func testASecondSurfaceOpeningTheSentryTabLaterKeepsTheNewMarkers() {
        rememberAnEarlierView()
        let store = makeStore()
        let first = makeHolder(store: store)
        first.select(.sentry)
        XCTAssertTrue(waitUntil { first.live.rowTexts.count == 2 })
        XCTAssertEqual(row(first.live, "Fresh")?.statusText, "new")
        XCTAssertNil(row(first.live, "Old")?.statusText)

        clock.advance(300)
        let second = makeHolder(store: store)
        second.select(.sentry)

        XCTAssertTrue(waitUntil { second.live.rowTexts.count == 2 })
        XCTAssertEqual(row(second.live, "Fresh")?.statusText, "new",
                       "the second surface compares with the same earlier view")
        XCTAssertEqual(row(first.live, "Fresh")?.statusText, "new", "and the first surface is not wiped either")
        XCTAssertEqual(lastViewed(), t0, "opening the second surface does not restamp the last view")
    }

    func testReleasingOneSurfaceDoesNotRecordALeaveWhileAnotherStillShowsTheTab() {
        rememberAnEarlierView()
        let store = makeStore()
        let first = makeHolder(store: store)
        let second = makeHolder(store: store)
        first.select(.sentry)
        clock.advance(300)
        second.select(.sentry)
        XCTAssertEqual(lastViewed(), t0)

        clock.advance(300)
        second.release()

        XCTAssertTrue(second.isGone, "precondition: the surface was deallocated")
        XCTAssertEqual(lastViewed(), t0, "the first surface is still looking at Sentry")
    }

    func testOnceBothSurfacesAreGoneTheLastViewedTimeIsWhenTheLastOneLeft() {
        rememberAnEarlierView()
        let store = makeStore()
        let first = makeHolder(store: store)
        let second = makeHolder(store: store)
        first.select(.sentry)
        second.select(.sentry)
        clock.advance(300)
        second.release()

        clock.advance(120)
        let leftAt = clock.now
        first.release()

        XCTAssertTrue(first.isGone && second.isGone)
        XCTAssertEqual(lastViewed(), leftAt)
    }

    func testASurfaceSwitchingAwayAndBackKeepsTheCountsBalanced() {
        rememberAnEarlierView()
        let store = makeStore()
        let first = makeHolder(store: store)
        let second = makeHolder(store: store)
        first.select(.sentry)                       // 1
        clock.advance(100)
        first.select(.todos)                        // 0: recorded
        XCTAssertEqual(lastViewed(), clock.now)
        let leftAt = clock.now

        second.select(.sentry)                      // 1: baseline = leftAt
        XCTAssertEqual(TeriSentryTab.tracker.baseline, leftAt)
        clock.advance(50)
        first.select(.sentry)                       // 2: nothing changes
        XCTAssertEqual(TeriSentryTab.tracker.baseline, leftAt)
        XCTAssertEqual(lastViewed(), leftAt)
        clock.advance(50)
        first.select(.todos)                        // 1: the second still shows it
        XCTAssertEqual(lastViewed(), leftAt, "the second surface is still on Sentry")

        clock.advance(50)
        let lastLeft = clock.now
        second.release()                                 // 0

        XCTAssertEqual(lastViewed(), lastLeft)
    }

    func testASurfaceThatSwitchesAwayAndBackAloneStillRecordsItsFinalLeave() {
        let holder = makeHolder(store: makeStore())
        holder.select(.sentry)
        clock.advance(60)
        holder.select(.todos)
        clock.advance(60)
        holder.select(.sentry)

        clock.advance(60)
        let leftAt = clock.now
        holder.release()

        XCTAssertEqual(lastViewed(), leftAt)
    }

    func testTheTrackerCanStillBeReplacedForTests() {
        let otherDefaults = makeDefaults()
        TeriSentryTab.tracker = TeriSentryViewTracker(defaults: otherDefaults, now: { [clock = self.clock] in clock.now })
        let holder = makeHolder(store: makeStore())

        holder.select(.sentry)

        XCTAssertEqual(otherDefaults.object(forKey: TeriSentryViewTracker.lastViewedKey) as? Date, t0)
        XCTAssertNil(lastViewed(), "the original tracker's defaults were not touched")
    }
}

// MARK: - Relative times refresh

final class TeriSentryRowRefreshTests: TeriSentryClockedTestCase {
    private let manual = ManualScheduler()

    private var pendingRefreshes: Int { manual.pendingDelays.filter { $0 == 60 }.count }

    private func makeSentryHolder() -> Holder {
        let holder = makeHolder(store: makeStore(), scheduler: manual.scheduler)
        holder.select(.sentry)
        return holder
    }

    private func dueText(_ holder: Holder, _ title: String) -> String? {
        row(holder.live, title)?.dueText
    }

    // Config

    func testOnlyTheSentryTabAsksForRowsToBeRefreshed() {
        XCTAssertEqual(TeriSentryTab.config.rowRefreshInterval, 60)
        XCTAssertNil(TeriPicksTab.config.rowRefreshInterval)
        XCTAssertNil(TeriTodosTab.config.rowRefreshInterval)
        XCTAssertNil(TeriJiraTab.config.rowRefreshInterval)
        XCTAssertNil(TeriRepoDocsTab.config.rowRefreshInterval)
    }

    // Scheduling

    func testWhileTheSentryTabIsSelectedARefreshIsScheduledOneMinuteOut() {
        let holder = makeSentryHolder()

        XCTAssertEqual(pendingRefreshes, 1)
        _ = holder
    }

    func testEachFiringArmsTheNextRefresh() {
        let holder = makeSentryHolder()

        manual.fireAll()
        XCTAssertEqual(pendingRefreshes, 1, "re-armed after the first firing")
        manual.fireAll()
        XCTAssertEqual(pendingRefreshes, 1, "and after the second")
        _ = holder
    }

    func testNothingIsScheduledOnTabsWithoutARefreshInterval() {
        let holder = makeHolder(store: makeStore(), scheduler: manual.scheduler)

        for tab in [TeriTab.todos, .jira, .repoDocs, .picks, .todos] {
            holder.select(tab)
            XCTAssertEqual(pendingRefreshes, 0, "\(tab)")
        }
        manual.fireAll()
        XCTAssertEqual(pendingRefreshes, 0)
    }

    func testARestoredSentryTabStartsRefreshingAtLaunch() {
        let defaults = makeDefaults()
        var state = TeriViewState()
        state.selectedTab = .sentry
        state.save(to: defaults)

        let holder = makeHolder(store: makeStore(), defaults: defaults, scheduler: manual.scheduler)

        XCTAssertEqual(holder.live.selectedTab, .sentry)
        XCTAssertEqual(pendingRefreshes, 1)
    }

    func testLeavingTheTabCancelsTheRefreshAndNothingIsRearmed() {
        let holder = makeSentryHolder()

        holder.select(.todos)

        XCTAssertEqual(pendingRefreshes, 0)
        manual.fireAll()
        XCTAssertEqual(pendingRefreshes, 0)
    }

    func testComingBackToTheTabArmsExactlyOneRefresh() {
        let holder = makeSentryHolder()
        holder.select(.todos)

        holder.select(.sentry)
        XCTAssertEqual(pendingRefreshes, 1)

        holder.select(.sentry)   // already there
        XCTAssertEqual(pendingRefreshes, 1, "reselecting the visible tab does not double up")
    }

    func testReleasingTheSurfaceCancelsTheRefresh() {
        let holder = makeSentryHolder()
        XCTAssertEqual(pendingRefreshes, 1)

        holder.release()

        XCTAssertTrue(holder.isGone, "precondition: the surface was deallocated")
        XCTAssertEqual(pendingRefreshes, 0)
    }

    func testAFiringAfterTheSurfaceIsGoneDoesNothingAndSchedulesNothing() {
        let holder = makeSentryHolder()
        holder.release()

        manual.fireAll()

        XCTAssertEqual(pendingRefreshes, 0)
    }

    // Re-rendering

    func testRelativeTimesAdvanceWhenTheRefreshFires() {
        let holder = makeSentryHolder()
        XCTAssertTrue(waitUntil { holder.live.rowTexts.count == 2 })
        XCTAssertEqual(dueText(holder, "Fresh"), "312 events / 24 h · 41 users · last seen 4 min ago")

        clock.advance(5 * 60)
        manual.fireAll()

        XCTAssertTrue(waitUntil { self.dueText(holder, "Fresh")?.hasSuffix("last seen 9 min ago") == true },
                      String(describing: dueText(holder, "Fresh")))
        XCTAssertTrue(dueText(holder, "Old")?.hasSuffix("last seen 1 h ago") ?? false, String(describing: dueText(holder, "Old")))

        clock.advance(60)
        manual.fireAll()
        XCTAssertTrue(waitUntil { self.dueText(holder, "Fresh")?.hasSuffix("last seen 10 min ago") == true },
                      "the re-armed refresh keeps the rows current: \(String(describing: dueText(holder, "Fresh")))")
    }

    func testRowOrderAndCountSurviveARefresh() {
        let holder = makeSentryHolder()
        XCTAssertTrue(waitUntil { holder.live.rowTexts.count == 2 })

        clock.advance(120)
        manual.fireAll()

        XCTAssertTrue(waitUntil { self.dueText(holder, "Fresh")?.hasSuffix("last seen 6 min ago") == true })
        XCTAssertEqual(holder.live.rowTexts.map(\.title), ["Fresh", "Old"])
        XCTAssertEqual(holder.live.tabButtonTitle(.sentry), "Sentry 2")
    }

    func testNewMarkersStayWhileTheTabStaysOpenAcrossARefresh() {
        rememberAnEarlierView()
        let holder = makeSentryHolder()
        XCTAssertTrue(waitUntil { self.row(holder.live, "Fresh")?.statusText == "new" })

        clock.advance(300)
        manual.fireAll()

        XCTAssertTrue(waitUntil { self.dueText(holder, "Fresh")?.hasSuffix("last seen 9 min ago") == true })
        XCTAssertEqual(row(holder.live, "Fresh")?.statusText, "new", "still compared with the view before this one")
    }

    func testAMarkerComputedWithAStaleBaselineDoesNotSurviveATabRoundTrip() {
        rememberAnEarlierView()
        let holder = makeSentryHolder()
        XCTAssertTrue(waitUntil { self.row(holder.live, "Fresh")?.statusText == "new" })

        clock.advance(300)
        holder.select(.todos)               // recorded as the last view
        clock.advance(300)
        holder.select(.sentry)              // baseline moves to when the user left

        XCTAssertTrue(waitUntil { self.row(holder.live, "Fresh")?.statusText == nil },
                      "the issue was on screen during the last view, so it is no longer new")
        XCTAssertNil(row(holder.live, "Old")?.statusText)
    }

    func testShowingTheTabAgainReRendersRelativeTimes() {
        let holder = makeSentryHolder()
        XCTAssertTrue(waitUntil { self.dueText(holder, "Fresh")?.hasSuffix("last seen 4 min ago") == true })
        holder.select(.todos)

        clock.advance(10 * 60)
        holder.select(.sentry)

        XCTAssertTrue(waitUntil { self.dueText(holder, "Fresh")?.hasSuffix("last seen 14 min ago") == true },
                      String(describing: dueText(holder, "Fresh")))
    }
}

// MARK: - WorkListView.refreshRows

final class WorkListRefreshRowsTests: XCTestCase {
    private final class Box { var suffix = "1" }

    private let box = Box()
    private var list: WorkListView!
    private var selections: [String?] = []

    override func setUp() {
        super.setUp()
        let box = self.box
        list = WorkListView(config: WorkListConfig(rowContent: { item in
            WorkRowContent(title: "\(item.title) @\(box.suffix)", accessibilityLabel: item.title)
        }), scheduler: ManualScheduler().scheduler)
        list.onSelectionChange = { [unowned self] item in self.selections.append(item?.id) }
    }

    private func flat(_ items: [WorkItem]) -> WorkListSnapshot {
        WorkListSnapshot(groups: [WorkGroup(key: nil, items: items)],
                         totalCount: items.count, filteredCount: items.count, facetCounts: [:])
    }

    func testRefreshingRowsRedrawsThemFromTheCurrentRowContent() {
        list.apply(snapshot: flat([WorkTestSupport.todo(1, "Alpha"), WorkTestSupport.todo(2, "Beta")]),
                   isLoading: false, placeholder: nil)
        XCTAssertEqual(list.visibleRows.map(\.title), ["Alpha @1", "Beta @1"])

        box.suffix = "2"
        list.refreshRows()

        XCTAssertEqual(list.visibleRows.map(\.title), ["Alpha @2", "Beta @2"])
    }

    func testRefreshingRowsKeepsTheSelectionWithoutReportingAChange() {
        list.apply(snapshot: flat([WorkTestSupport.todo(1, "Alpha"), WorkTestSupport.todo(2, "Beta")]),
                   isLoading: false, placeholder: nil)
        list.select(itemId: "todo:2")
        selections.removeAll()

        box.suffix = "2"
        list.refreshRows()

        XCTAssertEqual(list.selectedItem?.id, "todo:2")
        XCTAssertTrue(selections.isEmpty, "a periodic refresh is not a user selection: \(selections)")
    }

    func testRefreshingGroupedRowsKeepsTheGroupsAndRedrawsTheRows() {
        let snapshot = WorkListSnapshot(
            groups: [WorkGroup(key: "A", items: [WorkTestSupport.todo(1, "Alpha")]),
                     WorkGroup(key: "B", items: [WorkTestSupport.todo(2, "Beta")])],
            totalCount: 2, filteredCount: 2, facetCounts: [:])
        list.apply(snapshot: snapshot, isLoading: false, placeholder: nil)

        box.suffix = "2"
        list.refreshRows()

        XCTAssertEqual(list.visibleGroupHeaders, ["A", "B"])
        XCTAssertEqual(list.visibleRows.map(\.title), ["Alpha @2", "Beta @2"])
    }

    func testRefreshingBeforeAnythingWasAppliedIsHarmless() {
        list.refreshRows()

        XCTAssertTrue(list.visibleRows.isEmpty)
    }
}

// MARK: - Truncation note (fresh status with a reason)

final class TeriSentryTruncationNoteTests: TeriSentryClockedTestCase {
    private let note = "Showing the first 300 issues per search; narrow with a project filter."

    func testAFreshSentryWithAReasonShowsTheNoteAndStillListsItsIssuesAndCount() {
        let store = makeStore(status: SourceStatus(source: .sentry, state: .fresh, reason: note, count: 2))
        let holder = makeHolder(store: store)

        holder.select(.sentry)

        XCTAssertEqual(holder.live.visibleBannerMessage, "Sentry: \(note)")
        XCTAssertTrue(waitUntil { holder.live.rowTexts.count == 2 })
        XCTAssertEqual(holder.live.tabButtonTitle(.sentry), "Sentry 2", "the tab count is still the item count")
        XCTAssertNil(holder.live.emptyMessage)
    }

    func testTheNoteGoesAwayWhenSentryReportsFreshWithoutAReason() {
        let store = makeStore(status: SourceStatus(source: .sentry, state: .fresh, reason: note, count: 2))
        let holder = makeHolder(store: store)
        holder.select(.sentry)
        XCTAssertNotNil(holder.live.visibleBannerMessage)

        store.apply(status: SourceStatus(source: .sentry, state: .fresh, count: 2))

        XCTAssertTrue(waitUntil { holder.live.visibleBannerMessage == nil },
                      String(describing: holder.live.visibleBannerMessage))
    }

    func testAFreshSentryWithoutAReasonShowsNoBanner() {
        let holder = makeHolder(store: makeStore())

        holder.select(.sentry)

        XCTAssertNil(holder.live.visibleBannerMessage)
    }

    func testAnEmptySentryShowsNoBannerEvenWithAReason() {
        let store = WorkStore()
        store.sendFrame = { _ in }
        store.apply(status: SourceStatus(source: .sentry, state: .empty, reason: note, count: 0))
        let holder = makeHolder(store: store)

        holder.select(.sentry)

        XCTAssertNil(holder.live.visibleBannerMessage)
        XCTAssertFalse(holder.live.emptyMessage?.isEmpty ?? true, "the positive empty message still shows")
    }
}
