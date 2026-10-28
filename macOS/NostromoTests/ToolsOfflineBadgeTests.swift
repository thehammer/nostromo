import XCTest
import AppKit
import Combine

// The "Tools offline" health signal in the Mac app.
//
// A session whose `nostromo-mcp-bridge` lost its connection to the daemon keeps running but can no
// longer call any `mcp__nostromo__*` tool. The daemon sends `session_bridge {tag, connected}` on each
// change; the app shows a muted "Tools offline" badge for the ACTIVE focus's session once its bridge has
// been gone for more than ten seconds (a daemon restart reconnects it within a second or two, so a shorter
// absence is noise). A session that never reported a bridge (a terminal pane, an older daemon) is never
// offline.
//
// Four groups, from pure to integrated:
//   1. `ToolsOfflinePolicy`: the pure rule, with an injected clock.
//   2. The wire: `session_bridge` decodes; older frames still decode.
//   3. `ToolsOfflineBadgeView`: hidden by default, tooltip, accessibility, colours, and layout at the
//      narrow widths of the pace-bars strip.
//   4. `AppStore` and `PaceBarsView` together, on the real clock. Two tests wait out the real grace period
//      (about ten seconds each); they poll for the outcome rather than sleeping a fixed time.
//
// `ToolsOfflinePolicy`, `ToolsOfflineBadgeView`, `NostromodClient`, `AppStore` and `PaceBarsView` are
// compiled into this test target directly (a logic target, no host app).

// MARK: - Helpers

private func tobChannel(_ v: CGFloat) -> Double {
    let c = Double(v)
    return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
}

/// WCAG relative luminance of an sRGB colour.
private func tobLuminance(_ color: NSColor) -> Double {
    guard let c = color.usingColorSpace(.sRGB) else { return 0 }
    return 0.2126 * tobChannel(c.redComponent) + 0.7152 * tobChannel(c.greenComponent) + 0.0722 * tobChannel(c.blueComponent)
}

/// `color` composited over `background`, both resolved to sRGB.
private func tobOver(_ color: NSColor, _ background: NSColor) -> NSColor {
    let top = color.usingColorSpace(.sRGB) ?? color
    let bottom = background.usingColorSpace(.sRGB) ?? background
    let a = top.alphaComponent
    return NSColor(srgbRed: top.redComponent * a + bottom.redComponent * (1 - a),
                   green: top.greenComponent * a + bottom.greenComponent * (1 - a),
                   blue: top.blueComponent * a + bottom.blueComponent * (1 - a), alpha: 1)
}

/// Every text field below `view`, however deep.
private func tobTextFields(in view: NSView) -> [NSTextField] {
    var out: [NSTextField] = []
    for sub in view.subviews {
        if let field = sub as? NSTextField { out.append(field) }
        out += tobTextFields(in: sub)
    }
    return out
}

/// Spin the main run loop until `condition` holds or `timeout` passes. Returns whether it held.
private func tobSpin(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    return condition()
}

// MARK: - 1. The policy

final class ToolsOfflinePolicyTests: XCTestCase {

    /// An arbitrary fixed instant. No test reads the wall clock.
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    func testTheGracePeriodIsTenSeconds() {
        XCTAssertEqual(ToolsOfflinePolicy.grace, 10)
    }

    func testWithNoEventNoTagIsEverOffline() {
        let policy = ToolsOfflinePolicy()
        // A session that never reported a bridge (a terminal pane, an older daemon) never shows the badge,
        // however long the app has been running.
        for tag in ["cody-1", "terminal-pane", "fred", ""] {
            XCTAssertFalse(policy.isOffline(tag: tag, now: t0), tag)
            XCTAssertFalse(policy.isOffline(tag: tag, now: at(3_600)), tag)
            XCTAssertFalse(policy.isOffline(tag: tag, now: at(1_000_000)), tag)
        }
        XCTAssertTrue(policy.offlineTags(now: at(1_000_000)).isEmpty)
    }

    func testAConnectedReportForATagNeverSeenBeforeIsNotOffline() {
        var policy = ToolsOfflinePolicy()
        policy.bridgeChanged(tag: "cody-1", connected: true, now: t0)
        XCTAssertFalse(policy.isOffline(tag: "cody-1", now: t0))
        XCTAssertFalse(policy.isOffline(tag: "cody-1", now: at(3_600)))
        XCTAssertTrue(policy.offlineTags(now: at(3_600)).isEmpty)
    }

    func testALostBridgeIsNotOfflineWithinTheGracePeriod() {
        var policy = ToolsOfflinePolicy()
        policy.bridgeChanged(tag: "cody-1", connected: false, now: t0)
        for seconds in [0, 1, 5, 9, 9.9, 9.999] as [TimeInterval] {
            XCTAssertFalse(policy.isOffline(tag: "cody-1", now: at(seconds)), "after \(seconds)s")
        }
    }

    func testExactlyTheGracePeriodIsNotYetOfflineButJustPastItIs() {
        var policy = ToolsOfflinePolicy()
        policy.bridgeChanged(tag: "cody-1", connected: false, now: t0)

        XCTAssertFalse(policy.isOffline(tag: "cody-1", now: at(ToolsOfflinePolicy.grace)),
                       "offline only when STRICTLY more than the grace period has passed")
        XCTAssertTrue(policy.isOffline(tag: "cody-1", now: at(ToolsOfflinePolicy.grace + 0.001)))
        XCTAssertTrue(policy.isOffline(tag: "cody-1", now: at(11)))
        XCTAssertTrue(policy.isOffline(tag: "cody-1", now: at(86_400)))
    }

    func testOfflineTagsAndIsOfflineAgree() {
        var policy = ToolsOfflinePolicy()
        policy.bridgeChanged(tag: "cody-1", connected: false, now: t0)
        XCTAssertEqual(policy.offlineTags(now: at(11)), ["cody-1"])
        XCTAssertTrue(policy.isOffline(tag: "cody-1", now: at(11)))
        XCTAssertEqual(policy.offlineTags(now: at(5)), [])
    }

    func testReconnectingClearsAnOfflineTag() {
        var policy = ToolsOfflinePolicy()
        policy.bridgeChanged(tag: "cody-1", connected: false, now: t0)
        XCTAssertTrue(policy.isOffline(tag: "cody-1", now: at(30)))

        policy.bridgeChanged(tag: "cody-1", connected: true, now: at(30))
        XCTAssertFalse(policy.isOffline(tag: "cody-1", now: at(30)))
        XCTAssertFalse(policy.isOffline(tag: "cody-1", now: at(3_600)))
    }

    func testReconnectingWithinTheGracePeriodMeansItNeverShows() {
        var policy = ToolsOfflinePolicy()
        policy.bridgeChanged(tag: "cody-1", connected: false, now: t0)
        policy.bridgeChanged(tag: "cody-1", connected: true, now: at(2))
        XCTAssertFalse(policy.isOffline(tag: "cody-1", now: at(60)))
    }

    func testALossAfterAReconnectStartsAFreshGracePeriod() {
        var policy = ToolsOfflinePolicy()
        policy.bridgeChanged(tag: "cody-1", connected: false, now: t0)
        policy.bridgeChanged(tag: "cody-1", connected: true, now: at(30))
        policy.bridgeChanged(tag: "cody-1", connected: false, now: at(100))

        XCTAssertFalse(policy.isOffline(tag: "cody-1", now: at(105)), "the clock restarted at the new loss, not the old one")
        XCTAssertFalse(policy.isOffline(tag: "cody-1", now: at(110)))
        XCTAssertTrue(policy.isOffline(tag: "cody-1", now: at(110.5)))
    }

    func testARepeatedLostReportDoesNotRestartTheClock() {
        var policy = ToolsOfflinePolicy()
        policy.bridgeChanged(tag: "cody-1", connected: false, now: t0)
        policy.bridgeChanged(tag: "cody-1", connected: false, now: at(8))
        policy.bridgeChanged(tag: "cody-1", connected: false, now: at(9.5))

        XCTAssertTrue(policy.isOffline(tag: "cody-1", now: at(10.5)),
                      "the bridge has been gone since t0; later repeats of the same report change nothing")
    }

    func testSessionEndedClearsAnOfflineTagAndAWaitingOne() {
        var policy = ToolsOfflinePolicy()
        policy.bridgeChanged(tag: "offline", connected: false, now: t0)
        policy.bridgeChanged(tag: "waiting", connected: false, now: at(8))
        XCTAssertTrue(policy.isOffline(tag: "offline", now: at(12)))

        policy.sessionEnded(tag: "offline")
        policy.sessionEnded(tag: "waiting")

        XCTAssertFalse(policy.isOffline(tag: "offline", now: at(12)))
        XCTAssertFalse(policy.isOffline(tag: "waiting", now: at(3_600)))
        XCTAssertTrue(policy.offlineTags(now: at(3_600)).isEmpty)
        XCTAssertNil(policy.nextDeadline(now: at(12)))
    }

    func testANewProcessForAnEndedSessionStartsClean() {
        var policy = ToolsOfflinePolicy()
        policy.bridgeChanged(tag: "cody-1", connected: false, now: t0)
        policy.sessionEnded(tag: "cody-1")
        // The daemon announces the new process (`session_spawned`) before its bridge can report.
        policy.sessionStarted(tag: "cody-1")
        policy.bridgeChanged(tag: "cody-1", connected: false, now: at(100))

        XCTAssertFalse(policy.isOffline(tag: "cody-1", now: at(105)))
        XCTAssertTrue(policy.isOffline(tag: "cody-1", now: at(111)))
    }

    /// A bridge usually drops just after its session's process dies, so the daemon's "lost" report can
    /// arrive AFTER `session_exited`. A session that is not running has no tools to be missing.
    func testALateLostReportAfterTheSessionEndedNeverShowsTheBadge() {
        var policy = ToolsOfflinePolicy()
        policy.bridgeChanged(tag: "cody-1", connected: true, now: t0)
        policy.sessionEnded(tag: "cody-1")
        policy.bridgeChanged(tag: "cody-1", connected: false, now: at(1))

        XCTAssertFalse(policy.isOffline(tag: "cody-1", now: at(3_600)))
        XCTAssertTrue(policy.offlineTags(now: at(3_600)).isEmpty)
        XCTAssertNil(policy.nextDeadline(now: at(2)))
    }

    func testAConnectedReportAlsoMeansTheSessionIsRunningAgain() {
        var policy = ToolsOfflinePolicy()
        policy.sessionEnded(tag: "cody-1")
        policy.bridgeChanged(tag: "cody-1", connected: true, now: t0)
        policy.bridgeChanged(tag: "cody-1", connected: false, now: at(5))

        XCTAssertTrue(policy.isOffline(tag: "cody-1", now: at(16)))
    }

    func testSessionEndedForAnUnknownTagChangesNothing() {
        var policy = ToolsOfflinePolicy()
        policy.bridgeChanged(tag: "cody-1", connected: false, now: t0)
        policy.sessionEnded(tag: "never-reported")
        XCTAssertTrue(policy.isOffline(tag: "cody-1", now: at(11)))
        XCTAssertFalse(policy.isOffline(tag: "never-reported", now: at(11)))
    }

    func testResetForgetsEveryTag() {
        var policy = ToolsOfflinePolicy()
        policy.bridgeChanged(tag: "a", connected: false, now: t0)
        policy.bridgeChanged(tag: "b", connected: false, now: at(3))
        XCTAssertEqual(policy.offlineTags(now: at(20)), ["a", "b"])

        policy.reset()

        XCTAssertTrue(policy.offlineTags(now: at(20)).isEmpty)
        XCTAssertTrue(policy.offlineTags(now: at(3_600)).isEmpty)
        XCTAssertNil(policy.nextDeadline(now: at(1)))
    }

    func testTagsAreIndependentOfOneAnother() {
        var policy = ToolsOfflinePolicy()
        policy.bridgeChanged(tag: "a", connected: false, now: t0)
        policy.bridgeChanged(tag: "b", connected: false, now: at(6))
        policy.bridgeChanged(tag: "c", connected: true, now: at(6))

        XCTAssertEqual(policy.offlineTags(now: at(11)), ["a"], "b has been gone only 5s; c never was")
        XCTAssertEqual(policy.offlineTags(now: at(16.5)), ["a", "b"])

        policy.bridgeChanged(tag: "a", connected: true, now: at(17))
        XCTAssertEqual(policy.offlineTags(now: at(17)), ["b"], "a's reconnect leaves b alone")

        policy.sessionEnded(tag: "b")
        XCTAssertTrue(policy.offlineTags(now: at(17)).isEmpty)
    }

    // MARK: nextDeadline

    func testThereIsNoDeadlineWhenNothingIsWaiting() {
        var policy = ToolsOfflinePolicy()
        XCTAssertNil(policy.nextDeadline(now: t0))

        policy.bridgeChanged(tag: "cody-1", connected: true, now: t0)
        XCTAssertNil(policy.nextDeadline(now: t0), "a connected bridge is not waiting for anything")
    }

    func testTheDeadlineIsWhenTheGracePeriodEnds() {
        var policy = ToolsOfflinePolicy()
        policy.bridgeChanged(tag: "cody-1", connected: false, now: t0)

        XCTAssertEqual(policy.nextDeadline(now: t0), at(ToolsOfflinePolicy.grace))
        XCTAssertEqual(policy.nextDeadline(now: at(4)), at(ToolsOfflinePolicy.grace))
    }

    func testTheDeadlineIsTheEarliestOfTheTagsStillWaiting() {
        var policy = ToolsOfflinePolicy()
        policy.bridgeChanged(tag: "late", connected: false, now: at(7))
        policy.bridgeChanged(tag: "early", connected: false, now: t0)

        XCTAssertEqual(policy.nextDeadline(now: at(1)), at(ToolsOfflinePolicy.grace))
        // `early` has crossed: only `late` is still waiting.
        XCTAssertEqual(policy.nextDeadline(now: at(11)), at(7 + ToolsOfflinePolicy.grace))
    }

    func testThereIsNoDeadlineOnceEveryLostTagHasCrossed() {
        var policy = ToolsOfflinePolicy()
        policy.bridgeChanged(tag: "a", connected: false, now: t0)
        policy.bridgeChanged(tag: "b", connected: false, now: at(2))
        XCTAssertNil(policy.nextDeadline(now: at(13)))
        XCTAssertNil(policy.nextDeadline(now: at(3_600)))
    }

    func testAReconnectedTagHasNoDeadline() {
        var policy = ToolsOfflinePolicy()
        policy.bridgeChanged(tag: "cody-1", connected: false, now: t0)
        policy.bridgeChanged(tag: "cody-1", connected: true, now: at(3))
        XCTAssertNil(policy.nextDeadline(now: at(4)))
    }
}

// MARK: - 2. The wire

final class ToolsOfflineWireDecodeTests: XCTestCase {
    private var client: NostromodClient!

    override func setUp() {
        super.setUp()
        client = NostromodClient(socketPath: "/dev/null")
    }

    private func decode(_ type: String, _ text: String) throws -> ServerMsg {
        let raw = text.data(using: .utf8)!
        let json = try JSONSerialization.jsonObject(with: raw) as! [String: Any]
        return client.decode(type_: type, json: json, raw: raw)
    }

    func testASessionBridgeFrameDecodesAsConnected() throws {
        let msg = try decode("session_bridge", #"{"type":"session_bridge","tag":"cody-1","connected":true}"#)
        guard case .sessionBridge(let tag, let connected) = msg else { return XCTFail("expected .sessionBridge, got \(msg)") }
        XCTAssertEqual(tag, "cody-1")
        XCTAssertTrue(connected)
    }

    func testASessionBridgeFrameDecodesAsLost() throws {
        let msg = try decode("session_bridge", #"{"type":"session_bridge","tag":"cody-1","connected":false}"#)
        guard case .sessionBridge(let tag, let connected) = msg else { return XCTFail("expected .sessionBridge, got \(msg)") }
        XCTAssertEqual(tag, "cody-1")
        XCTAssertFalse(connected)
    }

    func testASessionBridgeFrameWithoutItsStateIsNotMistakenForOne() throws {
        let msg = try decode("session_bridge", #"{"type":"session_bridge","tag":"cody-1"}"#)
        if case .sessionBridge = msg { XCTFail("a frame without `connected` must not decode as a bridge state") }
    }

    func testASessionStateFrameWithNoBridgeKeyStillDecodes() throws {
        let msg = try decode("session_state", #"{"type":"session_state","tag":"cody-1","state":"mid_turn"}"#)
        guard case .sessionState(let tag, let state) = msg else { return XCTFail("expected .sessionState, got \(msg)") }
        XCTAssertEqual(tag, "cody-1")
        XCTAssertEqual(state, .midTurn)
    }

    func testASessionStateFrameThatCarriesAnUnrelatedBridgeKeyStillDecodes() throws {
        // Forward compatibility: an extra key on an existing frame is ignored.
        let msg = try decode("session_state", #"{"type":"session_state","tag":"cody-1","state":"idle","mcp_bridge_connected":false}"#)
        guard case .sessionState(let tag, let state) = msg else { return XCTFail("expected .sessionState, got \(msg)") }
        XCTAssertEqual(tag, "cody-1")
        XCTAssertEqual(state, .idle)
    }
}

// MARK: - 3. The badge view

final class ToolsOfflineBadgeViewTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.orderOut(nil) }
        windows = []
        super.tearDown()
    }

    // MARK: Content and state

    func testTheBadgeIsHiddenUntilToldOtherwise() {
        let badge = ToolsOfflineBadgeView()
        XCTAssertTrue(badge.isHidden)
        let framed = ToolsOfflineBadgeView(frame: NSRect(x: 0, y: 0, width: 80, height: 20))
        XCTAssertTrue(framed.isHidden)
    }

    func testApplyingOfflineShowsTheBadgeAndApplyingOnlineHidesItAgain() {
        let badge = ToolsOfflineBadgeView()
        badge.apply(offline: true)
        XCTAssertFalse(badge.isHidden)
        badge.apply(offline: true)
        XCTAssertFalse(badge.isHidden, "applying the same state twice changes nothing")
        badge.apply(offline: false)
        XCTAssertTrue(badge.isHidden)
    }

    func testTheBadgeSaysToolsAreOffline() {
        let badge = ToolsOfflineBadgeView()
        XCTAssertEqual(badge.text, ToolsOfflinePolicy.label)
        XCTAssertTrue(badge.text.lowercased().contains("offline"), badge.text)
    }

    func testTheTooltipTellsTheOperatorHowToRecover() {
        let badge = ToolsOfflineBadgeView()
        let tip = badge.toolTip ?? ""
        XCTAssertTrue(tip.contains("/mcp"), "the tooltip names the command that reconnects: \(tip)")
        XCTAssertTrue(tip.lowercased().contains("restart"), "the tooltip offers restarting the session: \(tip)")
        XCTAssertEqual(tip, ToolsOfflinePolicy.tooltip)
    }

    func testTheBadgeHasAnAccessibilityLabel() {
        let badge = ToolsOfflineBadgeView()
        XCTAssertTrue(badge.isAccessibilityElement(), "VoiceOver must be able to reach the badge")
        let label = badge.accessibilityLabel() ?? ""
        XCTAssertFalse(label.isEmpty)
        XCTAssertTrue(label.lowercased().contains("offline"), label)
    }

    // MARK: Colours

    func testTheBadgeColoursAreExplicitNotDynamicSystemColours() {
        // The app is pinned to Dark Aqua; a system-drawn label resolves dark-on-dark.
        XCTAssertEqual(ToolsOfflineBadgeView.textColor.type, .componentBased)
        XCTAssertEqual(ToolsOfflineBadgeView.fillColor.type, .componentBased)
        let badge = ToolsOfflineBadgeView()
        for field in tobTextFields(in: badge) {
            XCTAssertEqual(field.textColor?.type, NSColor.ColorType.componentBased)
        }
    }

    func testTheBadgeTextIsLegibleOnItsFillOverTheStripBackground() {
        let fill = tobOver(ToolsOfflineBadgeView.fillColor, Theme.bg)
        let text = tobLuminance(ToolsOfflineBadgeView.textColor)
        let ground = tobLuminance(fill)
        let ratio = (max(text, ground) + 0.05) / (min(text, ground) + 0.05)
        XCTAssertGreaterThan(text, ground, "light text on the dark pill, not the other way round")
        XCTAssertGreaterThanOrEqual(ratio, 4.5, "contrast \(ratio):1")
    }

    // MARK: Layout

    /// A pace-bars-height strip of `width` with a visible badge pinned the way `PaceBarsView` pins it
    /// (trailing -4, bottom -2, leading >= 4, top >= 2), laid out inside a real window.
    private func layOutBadge(inStripOf width: CGFloat, height: CGFloat = Theme.paceBarsHeight) -> (strip: NSView, badge: ToolsOfflineBadgeView) {
        let strip = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let badge = ToolsOfflineBadgeView()
        badge.translatesAutoresizingMaskIntoConstraints = false
        strip.addSubview(badge)
        NSLayoutConstraint.activate([
            badge.trailingAnchor.constraint(equalTo: strip.trailingAnchor, constant: -4),
            badge.bottomAnchor.constraint(equalTo: strip.bottomAnchor, constant: -2),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: strip.leadingAnchor, constant: 4),
            badge.topAnchor.constraint(greaterThanOrEqualTo: strip.topAnchor, constant: 2),
        ])
        badge.apply(offline: true)

        let window = NSWindow(contentRect: strip.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = strip
        windows.append(window)

        // Two passes: the label learns the width it may wrap at during the first, and reports its
        // wrapped height in the second.
        strip.layoutSubtreeIfNeeded()
        strip.layoutSubtreeIfNeeded()
        return (strip, badge)
    }

    func testTheBadgeStaysInsideTheStripAtEveryWidth() {
        for width in [400, 300, 120, 80, 60, 40] as [CGFloat] {
            let (strip, badge) = layOutBadge(inStripOf: width)
            let frame = badge.frame
            XCTAssertGreaterThan(frame.width, 0, "width \(width): the badge has a size")
            XCTAssertGreaterThan(frame.height, 0, "width \(width): the badge has a size")
            XCTAssertTrue(strip.bounds.contains(frame), "width \(width): badge \(frame) pokes out of \(strip.bounds)")
            XCTAssertGreaterThanOrEqual(frame.minX, 4 - 0.5, "width \(width): at least 4pt from the leading edge")
            XCTAssertLessThanOrEqual(frame.maxX, width - 4 + 0.5, "width \(width): at least 4pt from the trailing edge")
            XCTAssertGreaterThanOrEqual(frame.minY, 2 - 0.5, "width \(width): at least 2pt from the bottom")
            XCTAssertLessThanOrEqual(frame.maxY, strip.bounds.height - 2 + 0.5, "width \(width): at least 2pt from the top")
        }
    }

    func testTheBadgeSitsInTheBottomTrailingCorner() {
        let (strip, badge) = layOutBadge(inStripOf: 300)
        XCTAssertEqual(badge.frame.maxX, strip.bounds.width - 4, accuracy: 0.5)
        XCTAssertEqual(badge.frame.minY, 2, accuracy: 0.5)
    }

    func testANarrowStripMakesTheBadgeTallerNotWiderThanTheRoomItIsGiven() {
        let wide = layOutBadge(inStripOf: 300).badge.frame
        let narrow = layOutBadge(inStripOf: 40).badge.frame

        XCTAssertLessThanOrEqual(narrow.width, 40 - 4 - 4 + 0.5, "the badge shrinks to the room it has")
        XCTAssertLessThan(narrow.width, wide.width)
        XCTAssertGreaterThan(narrow.height, wide.height, "the label wraps to a second line instead of being cut off")
    }

    func testTheLabelWrapsRatherThanTruncates() {
        let badge = layOutBadge(inStripOf: 60).badge
        let fields = tobTextFields(in: badge)
        XCTAssertEqual(fields.count, 1)
        for field in fields {
            XCTAssertNotEqual(field.lineBreakMode, .byTruncatingTail)
            XCTAssertNotEqual(field.lineBreakMode, .byTruncatingMiddle)
            XCTAssertNotEqual(field.lineBreakMode, .byTruncatingHead)
            XCTAssertNotEqual(field.lineBreakMode, .byClipping)
            XCTAssertNotEqual(field.maximumNumberOfLines, 1)
        }
    }

    func testTheLabelGivesWayBeforeAnythingAroundIt() {
        let badge = ToolsOfflineBadgeView()
        let fields = tobTextFields(in: badge)
        XCTAssertEqual(fields.count, 1)
        for field in fields {
            let resistance = field.contentCompressionResistancePriority(for: .horizontal)
            XCTAssertLessThan(resistance.rawValue, NSLayoutConstraint.Priority.defaultHigh.rawValue,
                              "a high compression resistance would push the badge out of a narrow strip")
        }
    }

    func testTheBadgeDoesNotChangeTheStripsSize() {
        let (strip, _) = layOutBadge(inStripOf: 120)
        XCTAssertEqual(strip.frame.size.width, 120, accuracy: 0.5)
        XCTAssertEqual(strip.frame.size.height, Theme.paceBarsHeight, accuracy: 0.5)
    }
}

// MARK: - 4. AppStore and PaceBarsView

/// These run against the shared `AppStore` on the real clock, so each uses tags of its own and removes
/// them (`sessionExited`) when done.
final class ToolsOfflineAppStoreTests: XCTestCase {

    private var store: AppStore { AppStore.shared }
    private var usedTags: [String] = []
    private var savedActiveTag: String?

    override func setUp() {
        super.setUp()
        usedTags = []
        savedActiveTag = AppStore.shared.activeFocusSessionTag
    }

    override func tearDown() {
        for tag in usedTags { AppStore.shared.applyForTesting(.sessionExited(tag: tag, exitCode: 0)) }
        AppStore.shared.setActiveFocusSessionTag(savedActiveTag)
        super.tearDown()
    }

    private func tag(_ name: String) -> String {
        let t = "tob-\(name)-\(UUID().uuidString.prefix(8))"
        usedTags.append(t)
        return t
    }

    // MARK: AppStore (inside the grace period; instant)

    func testALostBridgeIsNotShownStraightAway() {
        let t = tag("fresh")
        store.applyForTesting(.sessionBridge(tag: t, connected: false))
        XCTAssertFalse(store.toolsOffline.contains(t), "inside the grace period a lost bridge is not yet worth the operator's attention")
    }

    func testASessionThatNeverReportedABridgeIsNeverOffline() {
        let t = tag("never")
        store.applyForTesting(.sessionState(tag: t, state: .idle))
        store.applyForTesting(.sessionBridge(tag: tag("other"), connected: false))
        XCTAssertFalse(store.toolsOffline.contains(t))
    }

    func testAConnectedBridgeIsNeverOffline() {
        let t = tag("connected")
        store.applyForTesting(.sessionBridge(tag: t, connected: true))
        XCTAssertFalse(store.toolsOffline.contains(t))
    }

    // MARK: AppStore (after the grace period; waits for the real ten seconds)

    func testALostBridgeShowsOnceTheGracePeriodPassesAndEveryWayOfEndingTheSessionOrReconnectingClearsIt() {
        let reconnects = tag("reconnects")
        let exits = tag("exits")
        let goesDown = tag("goes-down")
        let crashes = tag("crashes")
        let stays = tag("stays")
        let blip = tag("blip")
        let all = [reconnects, exits, goesDown, crashes, stays]
        for t in all { store.applyForTesting(.sessionBridge(tag: t, connected: false)) }
        for t in all { XCTAssertFalse(store.toolsOffline.contains(t), "not yet: \(t)") }
        // A bridge that reconnects inside the grace period must never show, even after the moment
        // its grace period would have ended.
        store.applyForTesting(.sessionBridge(tag: blip, connected: false))
        store.applyForTesting(.sessionBridge(tag: blip, connected: true))

        let shown = tobSpin(timeout: 20) { Set(all).isSubset(of: self.store.toolsOffline) }
        XCTAssertTrue(shown, "every lost bridge must be published as offline once the grace period has passed; got \(store.toolsOffline)")

        store.applyForTesting(.sessionBridge(tag: reconnects, connected: true))
        XCTAssertFalse(store.toolsOffline.contains(reconnects), "a reconnected bridge clears")

        store.applyForTesting(.sessionExited(tag: exits, exitCode: 0))
        XCTAssertFalse(store.toolsOffline.contains(exits), "an exited session has nothing to be offline")

        store.applyForTesting(.sessionDown(tag: goesDown, reason: .user))
        XCTAssertFalse(store.toolsOffline.contains(goesDown), "a stopped session has nothing to be offline")

        store.applyForTesting(.sessionState(tag: crashes, state: .crashed))
        XCTAssertFalse(store.toolsOffline.contains(crashes), "a crashed session has nothing to be offline")

        XCTAssertTrue(store.toolsOffline.contains(stays), "the others are untouched")
        XCTAssertFalse(store.toolsOffline.contains(blip), "a bridge that came back inside the grace period never showed")
    }

    // MARK: PaceBarsView

    func testThePaceBarsBadgeShowsOnlyForTheActiveFocusSessionAndOnlyOnceItsToolsAreOffline() {
        let active = tag("active")
        let other = tag("other")
        let never = tag("never")
        store.setActiveFocusSessionTag(active)
        let bars = PaceBarsView(frame: NSRect(x: 0, y: 0, width: 300, height: Theme.paceBarsHeight))
        let badge = bars.toolsOfflineBadge

        _ = tobSpin(timeout: 0.3) { false }   // let the first publish land
        XCTAssertTrue(badge.isHidden, "nothing is offline yet")

        store.applyForTesting(.sessionBridge(tag: active, connected: false))
        store.applyForTesting(.sessionBridge(tag: other, connected: false))
        _ = tobSpin(timeout: 0.5) { false }
        XCTAssertTrue(badge.isHidden, "inside the grace period the badge stays hidden")

        let offline = tobSpin(timeout: 20) { self.store.toolsOffline.contains(active) && self.store.toolsOffline.contains(other) }
        XCTAssertTrue(offline, "precondition: both lost bridges pass the grace period; got \(store.toolsOffline)")
        XCTAssertTrue(tobSpin(timeout: 3) { !badge.isHidden }, "the active focus's session is offline: the badge shows")

        // Another focus is offline too, but it is not the one on screen.
        store.setActiveFocusSessionTag(never)
        XCTAssertTrue(tobSpin(timeout: 3) { badge.isHidden }, "a session that never reported a bridge shows no badge")

        // Switching to the other offline session shows it again.
        store.setActiveFocusSessionTag(other)
        XCTAssertTrue(tobSpin(timeout: 3) { !badge.isHidden }, "the other offline session's badge shows when it is the active one")

        // No active focus: nothing to show.
        store.setActiveFocusSessionTag(nil)
        XCTAssertTrue(tobSpin(timeout: 3) { badge.isHidden }, "no active focus session: no badge")

        // Back to the first; reconnecting hides it.
        store.setActiveFocusSessionTag(active)
        XCTAssertTrue(tobSpin(timeout: 3) { !badge.isHidden })
        store.applyForTesting(.sessionBridge(tag: active, connected: true))
        XCTAssertTrue(tobSpin(timeout: 3) { badge.isHidden }, "the bridge is back: the badge goes")
    }
}
