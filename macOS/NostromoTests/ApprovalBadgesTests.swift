import XCTest
import AppKit
import UserNotifications
import NostromoKit

// AP3: reaching the person when the card's pane isn't in view.
//
// Approvals are a producer into the app-wide "needs you" source (MC4). These tests pin what comes out of
// it for approvals: the Dock badge (an injected setter), the red sidebar pill (`SidebarBadgeModel`,
// `NavTabItem`), the notification (an injected center, so the real one is never touched), and what a
// click on the notification does (an injected router). Nothing here uses a window the app owns.

private final class BadgeFakeCenter: NotificationCenterLike {
    var status: NeedsYouAuthorization
    private(set) var added: [UNNotificationRequest] = []
    private(set) var removedDelivered: [String] = []
    private(set) var authorizationRequests = 0

    init(status: NeedsYouAuthorization = .authorized) { self.status = status }

    func authorizationStatus(completion: @escaping (NeedsYouAuthorization) -> Void) { completion(status) }
    func requestAuthorization(completion: @escaping (Bool) -> Void) {
        authorizationRequests += 1
        if status == .notDetermined { status = .authorized }
        completion(status == .authorized)
    }
    func add(request: UNNotificationRequest) { added.append(request) }
    func removeDelivered(ids: [String]) { removedDelivered += ids }
    func removePending(ids: [String]) {}
}

private final class FakeRouter: ApprovalWindowRouting {
    private(set) var calls: [String] = []
    func bringAppForward() { calls.append("forward") }
    func showFocus(tag: String) { calls.append("focus:\(tag)") }
    func showCard(requestID: String, tag: String) { calls.append("card:\(requestID):\(tag)") }
}

/// A store, the coordinator behind the Dock badge and the notifier, and the producer between them.
private final class Rig {
    let recorder = ApprovalRecorder()
    let store: ApprovalStore
    let center: BadgeFakeCenter
    private(set) var dock: [String?] = []
    private(set) var coordinator: NeedsYouCoordinator!
    private(set) var badges: ApprovalBadges!

    init(center: BadgeFakeCenter = BadgeFakeCenter()) {
        store = recorder.makeStore()
        self.center = center
        coordinator = NeedsYouCoordinator(
            center: center, dockBadge: { [unowned self] in self.dock.append($0) }, jobTitle: { _ in nil },
            approvalRequest: { [store] in store.entry(id: $0)?.request })
        badges = ApprovalBadges(store: store) { [unowned self] items, baseline in
            self.coordinator.setProducer(ApprovalsNeedsYouProducer.name, items: items, baseline: baseline)
        }
    }

    func arrive(_ request: ApprovalRequestWire) { store.handle(.request(request)) }

    /// The daemon's list on (re)subscribe: it replaces what the store holds.
    func snapshot(_ requests: [ApprovalRequestWire]) { store.handle(.snapshot(requests)) }

    /// The ids of the notifications posted so far, in order.
    var postedIDs: [String] { center.added.map(\.identifier) }

    func end(_ id: String, tag: String = "cody-1") throws {
        store.handle(.resolved(try ApprovalTestRequests.resolved(id: id, outcome: "denied", tag: tag)))
    }
}

final class ApprovalBadgesTests: XCTestCase {

    // MARK: Dock badge (38)

    func testTheDockBadgeEqualsThePendingTotalAcrossFocusesAndClearsAtZero() throws {
        let rig = Rig()
        XCTAssertNil(rig.coordinator.dockLabel)

        rig.arrive(try ApprovalTestRequests.simpleRm(id: "a", tag: "cody-1"))
        XCTAssertEqual(rig.coordinator.dockLabel, "1")
        rig.arrive(try ApprovalTestRequests.simpleRm(id: "b", tag: "cody-1"))
        rig.arrive(try ApprovalTestRequests.simpleRm(id: "c", tag: "perri-1"))
        XCTAssertEqual(rig.coordinator.dockLabel, "3")

        try rig.end("a")
        XCTAssertEqual(rig.coordinator.dockLabel, "2")
        try rig.end("b")
        try rig.end("c", tag: "perri-1")
        XCTAssertNil(rig.coordinator.dockLabel, "cleared at zero")
        XCTAssertNil(rig.dock.last ?? nil)
    }

    func testAnAnsweredButUnconfirmedRequestStillCounts() throws {
        let rig = Rig()
        rig.arrive(try ApprovalTestRequests.simpleRm(id: "a"))
        XCTAssertTrue(rig.store.answer("a", ApprovalDecisionWire(kind: .deny), windowID: "w"))
        XCTAssertEqual(rig.coordinator.dockLabel, "1", "it is pending until the daemon says it ended")
    }

    // MARK: Sidebar pill (37)

    func testTheSnapshotCountsPendingPerFocusAndLeavesDecisionsToTheirDot() throws {
        let rig = Rig()
        rig.arrive(try ApprovalTestRequests.simpleRm(id: "a", tag: "cody-1"))
        rig.arrive(try ApprovalTestRequests.simpleRm(id: "b", tag: "cody-1"))
        rig.arrive(try ApprovalTestRequests.simpleRm(id: "c", tag: "perri-1"))
        rig.coordinator.setAttentionTags(["cody-1"])

        let counts = SidebarBadgeModel.needsYouNowCounts(from: rig.coordinator.snapshot)

        XCTAssertEqual(counts, ["cody-1": 2, "perri-1": 1])
    }

    func testTheNeedsYouNowLevelOutranksAttentionAndKeepsTheSecondLine() {
        var registry = FocusBadgeRegistry()
        registry.publish(tag: "fred", sourceKey: "fred",
                         badge: FocusBadge(pill: "12", detail: "Next: Eng sync", level: .attention, accessibilityLabel: "Fred, 12 unread"))
        registry.publish(tag: "fred", sourceKey: "needs-you-now", badge: .needsYouNow(count: 2))

        let badge = registry.badge(for: "fred")

        XCTAssertEqual(badge?.level, .needsYouNow)
        XCTAssertEqual(badge?.pill, "2")
        XCTAssertEqual(badge?.detail, "Next: Eng sync")
        XCTAssertEqual(badge?.accessibilityLabel, "2 waiting on you")
        XCTAssertEqual(registry.attentionTags, ["fred"], "the dot logic still sees the attention source")
    }

    func testTheModelPublishesChangesAndClearsAFocusThatNoLongerNeedsYou() {
        var model = SidebarBadgeModel()
        model.setNeedsYouNow(["cody-1": 1, "perri-1": 3])
        XCTAssertEqual(model.badge(for: "cody-1")?.pill, "1")
        XCTAssertEqual(model.badge(for: "perri-1")?.level, .needsYouNow)

        model.setNeedsYouNow(["cody-1": 2])
        XCTAssertEqual(model.badge(for: "cody-1")?.pill, "2")
        XCTAssertNil(model.badge(for: "perri-1"))

        model.setNeedsYouNow([:])
        XCTAssertNil(model.badge(for: "cody-1"))
    }

    func testThePurpleDecisionDotAndTheRedPillCanShowTogether() {
        var model = SidebarBadgeModel()
        model.setNeedsYouNow(["cody-1": 1])
        XCTAssertEqual(model.combinedAttentionTags(storeTags: ["cody-1"]), ["cody-1"], "the dot's tag is untouched")
        XCTAssertEqual(model.badge(for: "cody-1")?.pill, "1")
    }

    private func makeItem(secondary: String?, width: CGFloat = 180) -> NavTabItem {
        let focus = Focus.builtIns.first { $0.agentTag == "fred" }!
        let item = NavTabItem(focus: focus, label: "Fred", secondary: secondary, indented: false)
        item.frame = NSRect(x: 0, y: 0, width: width,
                            height: secondary == nil ? Theme.navItemHeight : Theme.navItemSubtitleHeight)
        item.layoutSubtreeIfNeeded()
        return item
    }

    func testThePillIsRedShowsTheCountAndNeverChangesTheRowHeight() {
        for secondary in [nil, "base line"] as [String?] {
            for attention in [false, true] {
                let item = makeItem(secondary: secondary)
                let expected = secondary == nil ? Theme.navItemHeight : Theme.navItemSubtitleHeight
                let fitting = item.fittingSize.height
                item.needsAttention = attention

                item.setBadge(.needsYouNow(count: 12))
                item.layoutSubtreeIfNeeded()
                XCTAssertEqual(item.pillText, "12")
                XCTAssertTrue(item.showsNeedsYouNow)
                XCTAssertEqual(item.frame.height, expected, "pill shown (attention dot: \(attention))")
                XCTAssertEqual(item.fittingSize.height, fitting)
                XCTAssertEqual(item.accessibilityLabel(), "12 waiting on you, needs you now")
                if attention, let pill = item.pillFrame, let dot = item.attentionDotFrame {
                    XCTAssertLessThanOrEqual(pill.maxX, dot.minX, "the pill sits left of the dot")
                }

                item.setBadge(nil)
                item.layoutSubtreeIfNeeded()
                XCTAssertNil(item.pillText)
                XCTAssertFalse(item.showsNeedsYouNow)
                XCTAssertEqual(item.frame.height, expected, "pill hidden (attention dot: \(attention))")
                XCTAssertEqual(item.fittingSize.height, fitting)
            }
        }
    }

    func testTheRedPillsDigitHasAtLeastAAContrast() throws {
        func luminance(_ color: NSColor) throws -> Double {
            let c = try XCTUnwrap(color.usingColorSpace(.sRGB))
            func lin(_ v: CGFloat) -> Double { let d = Double(v); return d <= 0.03928 ? d / 12.92 : pow((d + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
        }
        let red = try luminance(Theme.needsYouNow), white = try luminance(.white)
        XCTAssertGreaterThanOrEqual((white + 0.05) / (red + 0.05), 4.5)
    }

    // MARK: Notification (39)

    func testOneNotificationPerRequestWithTheToolAndFirstWordOnly() throws {
        let rig = Rig()
        let request = try ApprovalTestRequests.compound()

        rig.arrive(request)
        rig.arrive(request)   // a replayed frame

        XCTAssertEqual(rig.center.added.count, 1)
        let sent = rig.center.added[0]
        XCTAssertEqual(sent.identifier, "approvals:req-1")
        XCTAssertEqual(sent.content.title, "Cody needs approval")
        XCTAssertEqual(sent.content.body, "Bash · rm")
        XCTAssertEqual(sent.content.threadIdentifier, "cody-1")
        XCTAssertEqual(sent.content.categoryIdentifier, "", "no category, so no actions")
        XCTAssertNil(sent.content.sound, "a banner, never a sound")
        XCTAssertNotEqual(sent.content.interruptionLevel, .timeSensitive)
        XCTAssertNil(sent.trigger)
    }

    func testNoFixtureEverLeaksASecondWordAPathOrTheReason() throws {
        let fixtures: [ApprovalRequestWire] = [
            try ApprovalTestRequests.simpleRm(), try ApprovalTestRequests.compound(),
            try ApprovalTestRequests.heredoc300(), try ApprovalTestRequests.bidi(),
        ]
        for request in fixtures {
            let rig = Rig()
            rig.arrive(request)
            let content = try XCTUnwrap(rig.center.added.first?.content, "a notification for \(request.requestId)")
            let text = content.title + "\n" + content.body
            XCTAssertEqual(content.body.split(separator: " ").count, 3, "tool, dot, one word: \(content.body)")
            for leak in ["-rf", "build", "target", "/tmp", "notes", "EOF", request.reason.text, "settings.json"] {
                XCTAssertFalse(text.contains(leak), "`\(leak)` leaked into: \(text)")
            }
            XCTAssertTrue(content.userInfo.values.allSatisfy { $0 is String })
        }
    }

    func testANonBashToolShowsTheToolNameOnly() throws {
        let rig = Rig()
        let request = try ApprovalTestRequests.edit()
        rig.arrive(request)
        let body = try XCTUnwrap(rig.center.added.first?.content.body)
        XCTAssertEqual(body, request.displayName)
        XCTAssertFalse(body.contains("·"))
    }

    func testTheNotificationIsRemovedWhenTheRequestResolves() throws {
        let rig = Rig()
        rig.arrive(try ApprovalTestRequests.simpleRm(id: "a"))
        try rig.end("a")
        XCTAssertEqual(rig.center.removedDelivered, ["approvals:a"])
    }

    func testDeniedPermissionPostsNothingAndDoesNotAskAgain() throws {
        let rig = Rig(center: BadgeFakeCenter(status: .denied))
        rig.arrive(try ApprovalTestRequests.simpleRm())
        XCTAssertTrue(rig.center.added.isEmpty)
        XCTAssertEqual(rig.center.authorizationRequests, 0)
        XCTAssertEqual(rig.coordinator.dockLabel, "1", "the Dock badge does not need the permission")
    }

    func testAuthorizationIsAskedLazilyOnTheFirstPendingApproval() throws {
        let rig = Rig(center: BadgeFakeCenter(status: .notDetermined))
        XCTAssertEqual(rig.center.authorizationRequests, 0)
        rig.arrive(try ApprovalTestRequests.simpleRm())
        XCTAssertEqual(rig.center.authorizationRequests, 1)
        XCTAssertEqual(rig.center.added.count, 1)
    }

    // MARK: First snapshot, reconnect and permission (A3F-1)

    private func rm(_ id: String, _ tag: String = "cody-1") throws -> ApprovalRequestWire {
        try ApprovalTestRequests.simpleRm(id: id, tag: tag)
    }

    func testRequestsFoundWaitingAtLaunchAlertNobodyButStillCountAndClearAtZero() throws {
        let rig = Rig()

        rig.snapshot([try rm("a"), try rm("b")])

        XCTAssertTrue(rig.center.added.isEmpty, "what a relaunch finds waiting is the baseline, not a burst")
        XCTAssertEqual(rig.coordinator.dockLabel, "2")
        XCTAssertEqual(SidebarBadgeModel.needsYouNowCounts(from: rig.coordinator.snapshot), ["cody-1": 2])

        rig.arrive(try rm("c"))
        XCTAssertEqual(rig.postedIDs, ["approvals:c"], "the first request after the baseline alerts, and only it")
        XCTAssertEqual(rig.coordinator.dockLabel, "3")

        try rig.end("a")
        try rig.end("b")
        try rig.end("c")
        rig.recorder.runScheduled()

        XCTAssertNil(rig.coordinator.dockLabel)
        XCTAssertTrue(SidebarBadgeModel.needsYouNowCounts(from: rig.coordinator.snapshot).isEmpty)
        XCTAssertEqual(rig.dock, ["2", "3", "2", "1", nil], "each change once, and the clear exactly once")
    }

    func testAnEmptyFirstSnapshotStillBaselinesSoTheFirstRealArrivalAlerts() throws {
        let rig = Rig()

        rig.snapshot([])
        XCTAssertTrue(rig.center.added.isEmpty)

        rig.arrive(try rm("a"))
        XCTAssertEqual(rig.postedIDs, ["approvals:a"], "the first arrival after an empty snapshot is not swallowed")
        XCTAssertEqual(rig.coordinator.dockLabel, "1")
    }

    func testAnArrivalBeforeTheSnapshotAlertsAndTheSnapshotThatListsItDoesNotRepostOrAlertTheRest() throws {
        let rig = Rig()
        rig.arrive(try rm("a"))
        XCTAssertEqual(rig.postedIDs, ["approvals:a"], "before the snapshot nothing is baselined")

        rig.snapshot([try rm("a"), try rm("b")])

        XCTAssertEqual(rig.postedIDs, ["approvals:a"], "b was already waiting at the snapshot; a is not posted twice")
        XCTAssertEqual(rig.coordinator.dockLabel, "2")
    }

    func testAReconnectThatDropsAndRelistsARequestDoesNotAlertItAgain() throws {
        let rig = Rig()
        rig.snapshot([try rm("a")])
        rig.arrive(try rm("b"))
        XCTAssertEqual(rig.postedIDs, ["approvals:b"])

        rig.snapshot([try rm("a")])                    // the daemon's list no longer holds b
        XCTAssertEqual(rig.coordinator.dockLabel, "1")
        rig.snapshot([try rm("a"), try rm("b")])       // and then holds it again

        XCTAssertEqual(rig.postedIDs, ["approvals:b"], "b alerted once")
        XCTAssertEqual(rig.coordinator.dockLabel, "2", "it still counts")

        rig.snapshot([try rm("a"), try rm("b"), try rm("c")])
        XCTAssertEqual(rig.postedIDs, ["approvals:b", "approvals:c"], "a request the daemon never listed before alerts")
    }

    func testARequestAlertedLiveIsNotRepeatedWhenASnapshotDropsAndRelistsIt() throws {
        let rig = Rig()
        rig.arrive(try rm("a"))
        XCTAssertEqual(rig.postedIDs, ["approvals:a"])

        rig.snapshot([])
        XCTAssertNil(rig.coordinator.dockLabel)
        rig.snapshot([try rm("a")])

        XCTAssertEqual(rig.postedIDs, ["approvals:a"], "no repeat")
        XCTAssertEqual(rig.coordinator.dockLabel, "1")
    }

    func testAnApprovalAfterTheBaselineWhilePermissionIsUndecidedPromptsOnceThenPostsOnce() throws {
        let rig = Rig(center: BadgeFakeCenter(status: .notDetermined))
        rig.snapshot([try rm("a")])
        XCTAssertEqual(rig.center.authorizationRequests, 0, "the baseline never prompts")
        XCTAssertTrue(rig.center.added.isEmpty)

        rig.arrive(try rm("b"))

        XCTAssertEqual(rig.center.authorizationRequests, 1)
        XCTAssertEqual(rig.postedIDs, ["approvals:b"], "granted: the request that asked is announced, once")

        rig.arrive(try rm("c"))
        XCTAssertEqual(rig.postedIDs, ["approvals:b", "approvals:c"])
        XCTAssertEqual(rig.center.authorizationRequests, 1, "never a second prompt")
    }

    // MARK: Presentation while the app is active

    func testAnApprovalsBannerOnlyYieldsToItsOwnCardNeverToTheMotherView() {
        let info: [AnyHashable: Any] = ["producer": "approvals", "tag": "cody-1"]
        var motherViewAsked = false

        XCTAssertEqual(NeedsYouPresentation.options(userInfo: info, cardIsVisible: { _ in false },
                                                    motherViewIsVisible: { motherViewAsked = true; return true }),
                       [.banner], "the Mother view being open does not swallow an approval")
        XCTAssertFalse(motherViewAsked, "an approval's banner has nothing to do with the Mother view")

        XCTAssertEqual(NeedsYouPresentation.options(userInfo: info, cardIsVisible: { $0 == "cody-1" },
                                                    motherViewIsVisible: { false }),
                       [], "its card is on screen in the key window")

        XCTAssertEqual(NeedsYouPresentation.options(userInfo: info, cardIsVisible: { $0 == "perri-1" },
                                                    motherViewIsVisible: { true }),
                       [.banner], "another focus's card being on screen does not hide this one")
    }

    func testMothersBannerYieldsToTheMotherViewOnlyNotToAnApprovalCard() {
        let info: [AnyHashable: Any] = ["producer": "mother", "jobId": "j1"]

        XCTAssertEqual(NeedsYouPresentation.options(userInfo: info, cardIsVisible: { _ in true },
                                                    motherViewIsVisible: { true }), [])
        XCTAssertEqual(NeedsYouPresentation.options(userInfo: info, cardIsVisible: { _ in true },
                                                    motherViewIsVisible: { false }), [.banner])
    }

    // MARK: Pill in every window

    private func dynamicFocus(tag: String, agent: String) -> Focus {
        var focus = Focus(id: tag, agentTag: agent, projectPath: "/Users/hammer/Code/nostromo", isBuiltIn: false, org: "Carefeed")
        focus.daemonTag = tag
        return focus
    }

    /// One window's sidebar: its own badge model and its own rows, fed the way `TabBarView.updateBadges` does.
    private struct SidebarWindow {
        var model = SidebarBadgeModel()
        let rows: [String: NavTabItem]

        init(focuses: [Focus]) {
            var rows: [String: NavTabItem] = [:]
            for focus in focuses {
                let item = NavTabItem(focus: focus, label: focus.displayName, secondary: "main", indented: false)
                item.frame = NSRect(x: 0, y: 0, width: 180, height: Theme.navItemSubtitleHeight)
                item.layoutSubtreeIfNeeded()
                rows[focus.sessionTag] = item
            }
            self.rows = rows
        }

        mutating func apply(_ snapshot: NeedsYouSnapshot) {
            model.setNeedsYouNow(SidebarBadgeModel.needsYouNowCounts(from: snapshot))
            for (tag, item) in rows {
                item.setBadge(model.badge(for: tag))
                item.layoutSubtreeIfNeeded()
            }
        }

        func activate(_ tag: String) { rows.forEach { $0.value.isActive = ($0.key == tag) } }
    }

    func testTwoWindowsShowTheSamePillAndSwitchingFocusNeverChangesItOrTheRowHeight() throws {
        let cody = dynamicFocus(tag: "cody-1", agent: "cody"), perri = dynamicFocus(tag: "perri-1", agent: "perri")
        var left = SidebarWindow(focuses: [cody, perri]), right = SidebarWindow(focuses: [cody, perri])
        let rig = Rig()
        rig.snapshot([try rm("a"), try rm("b")])
        left.activate("cody-1")      // the person is looking at cody-1 in the left window
        right.activate("perri-1")    // and at another focus in the right one

        left.apply(rig.coordinator.snapshot)
        right.apply(rig.coordinator.snapshot)

        for window in [left, right] {
            XCTAssertEqual(window.rows["cody-1"]?.pillText, "2")
            XCTAssertEqual(window.rows["cody-1"]?.showsNeedsYouNow, true)
            XCTAssertNil(window.rows["perri-1"]?.pillText, "only the focus that is waiting shows a pill")
            for item in window.rows.values {
                XCTAssertEqual(item.frame.height, Theme.navItemSubtitleHeight)
            }
        }
        let leftCody = try XCTUnwrap(left.rows["cody-1"])
        let fitting = leftCody.fittingSize.height

        // Each window switches focus: the pill is the same on screen or off it.
        left.activate("perri-1")
        right.activate("cody-1")
        left.apply(rig.coordinator.snapshot)
        right.apply(rig.coordinator.snapshot)

        for window in [left, right] {
            XCTAssertEqual(window.rows["cody-1"]?.pillText, "2", "the same count after a focus switch")
            XCTAssertNil(window.rows["perri-1"]?.pillText)
            for item in window.rows.values {
                XCTAssertEqual(item.frame.height, Theme.navItemSubtitleHeight)
            }
        }
        XCTAssertEqual(leftCody.fittingSize.height, fitting)

        // One answered request: both windows follow the same snapshot.
        try rig.end("a")
        left.apply(rig.coordinator.snapshot)
        right.apply(rig.coordinator.snapshot)
        XCTAssertEqual(left.rows["cody-1"]?.pillText, "1")
        XCTAssertEqual(right.rows["cody-1"]?.pillText, "1")
    }

    // MARK: The click

    func testAClickBringsTheAppForwardSelectsTheFocusAndExpandsTheCard() throws {
        let rig = Rig()
        rig.arrive(try ApprovalTestRequests.compound())
        rig.store.setCollapsed("req-1", true)
        let router = FakeRouter()
        let notifier = ApprovalNotifier(router: router, store: rig.store)
        let userInfo = try XCTUnwrap(rig.center.added.first?.content.userInfo)

        XCTAssertTrue(notifier.handleClick(userInfo: userInfo))

        XCTAssertEqual(router.calls, ["forward", "focus:cody-1", "card:req-1:cody-1"])
        XCTAssertFalse(rig.store.isCollapsed("req-1"))
        XCTAssertEqual(rig.store.entry(id: "req-1")?.state, .pending, "a click answers nothing")
        XCTAssertTrue(rig.recorder.sent.isEmpty)
    }

    func testAClickForARequestThatIsGoneStillGoesToItsFocus() {
        let router = FakeRouter()
        let notifier = ApprovalNotifier(router: router, store: ApprovalRecorder().makeStore())
        XCTAssertTrue(notifier.handleClick(userInfo: ["producer": "approvals", "tag": "cody-1", "requestId": "gone"]))
        XCTAssertEqual(router.calls, ["forward", "focus:cody-1"])
    }

    func testAnotherProducersNotificationIsNotRouted() {
        let router = FakeRouter()
        let notifier = ApprovalNotifier(router: router, store: ApprovalRecorder().makeStore())
        XCTAssertFalse(notifier.handleClick(userInfo: ["producer": "mother", "jobId": "j1"]))
        XCTAssertTrue(router.calls.isEmpty)
    }

    func testNoBannerWhileTheCardIsOnScreenInTheKeyWindow() {
        let info: [AnyHashable: Any] = ["producer": "approvals", "tag": "cody-1"]
        XCTAssertFalse(ApprovalNotifier.shouldPresent(userInfo: info, cardIsVisible: { $0 == "cody-1" }))
        XCTAssertTrue(ApprovalNotifier.shouldPresent(userInfo: info, cardIsVisible: { _ in false }))
        XCTAssertTrue(ApprovalNotifier.shouldPresent(userInfo: ["producer": "mother"], cardIsVisible: { _ in true }))
    }

    // MARK: Store: collapse and pending

    func testCollapsedStateIsPerRequestInTheStoreAndGoneWithTheRequest() throws {
        let rig = Rig()
        rig.arrive(try ApprovalTestRequests.simpleRm(id: "a"))
        rig.arrive(try ApprovalTestRequests.simpleRm(id: "b"))
        var changes: [String] = []
        let sub = rig.store.changes.sink { changes.append($0) }
        defer { sub.cancel() }

        rig.store.setCollapsed("a", true)
        XCTAssertTrue(rig.store.isCollapsed("a"))
        XCTAssertFalse(rig.store.isCollapsed("b"))
        XCTAssertEqual(changes, ["cody-1"])
        rig.store.setCollapsed("a", true)
        XCTAssertEqual(changes.count, 1, "no change, no event")

        try rig.end("a")
        rig.recorder.runScheduled()
        XCTAssertFalse(rig.store.isCollapsed("a"))
        rig.store.setCollapsed("a", true)
        XCTAssertFalse(rig.store.isCollapsed("a"), "an unknown request cannot be collapsed")
    }

    func testPendingRequestsExcludesEndedOnesAcrossFocuses() throws {
        let rig = Rig()
        rig.arrive(try ApprovalTestRequests.simpleRm(id: "a", tag: "cody-1"))
        rig.arrive(try ApprovalTestRequests.simpleRm(id: "b", tag: "perri-1"))
        try rig.end("a")
        XCTAssertEqual(rig.store.pendingRequests().map(\.requestId), ["b"])
    }
}
