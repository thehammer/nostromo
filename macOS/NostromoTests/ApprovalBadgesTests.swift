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
        badges = ApprovalBadges(store: store) { [unowned self] items in
            self.coordinator.setProducer(ApprovalsNeedsYouProducer.name, items: items)
        }
    }

    func arrive(_ request: ApprovalRequestWire) { store.handle(.request(request)) }

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
