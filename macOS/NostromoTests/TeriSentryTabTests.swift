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
        XCTAssertEqual(config.list?.menuFacets, [.project, .environment])
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

    func testTheStatusColumnShowsTheEnvironment() {
        XCTAssertEqual(content(issue(1, environment: "production")).statusText, "production")
        let none = content(issue(1, environment: nil)).statusText
        XCTAssertTrue(none == nil || none == "", String(describing: none))
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

        XCTAssertEqual(c.statusText, "new · production")
        XCTAssertEqual(c.accessibilityLabel,
                       "Sentry issue, portal-production, TypeError in FacesheetParser, 312 events, last seen 4 minutes ago, new")
    }

    func testAnIssueOlderThanTheLastViewIsNotMarkedNew() {
        TeriSentryTab.tracker = trackerWithLastView(at: minutesAgo(60))
        let c = content(issue(1, environment: "production", createdAt: minutesAgo(120), lastSeen: minutesAgo(4)))

        XCTAssertEqual(c.statusText, "production")
        XCTAssertFalse(c.accessibilityLabel.hasSuffix(", new"), c.accessibilityLabel)
    }

    func testANewIssueWithNoEnvironmentIsJustMarkedNew() {
        TeriSentryTab.tracker = trackerWithLastView(at: minutesAgo(60))
        XCTAssertEqual(content(issue(1, environment: nil, createdAt: minutesAgo(10))).statusText, "new")
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

    func testARowShowsTheLevelEventsAndEnvironmentThroughTheRealSurface() {
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

    func testFilteringByEnvironmentKeepsOnlyThatEnvironmentsIssues() {
        var f = WorkFilter(); f.environments = ["staging"]
        XCTAssertEqual(titles(snapshot(f)), ["B"])
    }

    func testProjectAndEnvironmentFiltersCombine() {
        var f = WorkFilter(); f.projects = ["portal-production"]; f.environments = ["production"]
        XCTAssertEqual(titles(snapshot(f)), ["A"])
    }

    func testTheMenusOfferEveryProjectAndEnvironmentWithCounts() {
        let s = snapshot(WorkFilter())
        XCTAssertEqual(s.facetCounts[.project], ["portal-production": 2, "payments-production": 2])
        XCTAssertEqual(s.facetCounts[.environment], ["production": 3, "staging": 1])
    }

    func testAFacetsCountsIgnoreItsOwnFilterButRespectTheOther() {
        var f = WorkFilter(); f.environments = ["production"]
        let s = snapshot(f)
        XCTAssertEqual(s.facetCounts[.project], ["portal-production": 1, "payments-production": 2],
                       "project counts are narrowed by the environment filter")
        XCTAssertEqual(s.facetCounts[.environment], ["production": 3, "staging": 1],
                       "environment counts ignore the environment filter itself")
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
