import XCTest
import AppKit

// `FollowModel`: what a terminal pane's Follow control says and offers, from the daemon's `TerminalInfo`
// and the focus list alone. Following is invitation-only: the model only says what a person may choose.
//   * The badge says who follows, by the focus's LABEL (what the sidebar shows), never the bare tag
//     unless the focus is gone; it is never red (a red header means "production").
//   * The invite popover starts on the focus that owns the pane (or the agent that asked for a remote
//     pane), with a warning that names where the output goes; a remote pane names its environment.
//   * "Include what's on screen now" is off by default.

final class FollowModelTests: XCTestCase {

    private let core = FollowFocusOption(tag: "core-1", name: "Core")
    private let claudia = FollowFocusOption(tag: "claudia-1", name: "Claudia")
    private let cody = FollowFocusOption(tag: "cody-1", name: "Cody")

    private func target(_ environment: String) -> TerminalTarget {
        TerminalTarget(project: "admin-portal", environment: environment, service: "scheduler", shellType: "shell")
    }

    private func info(tag: String = "core-1", kind: TerminalKind = .local, target: TerminalTarget? = nil,
                      status: TerminalStatus = .running, requestedBy: TerminalRequester? = nil,
                      follower: TerminalFollower? = nil) -> TerminalInfo {
        TerminalInfo(terminalId: "t1", tag: tag, paneId: "terminal-a", kind: kind, label: "Terminal", cwd: nil, target: target,
                     status: status, exitCode: nil, endedReason: nil, cols: 80, rows: 24,
                     requestedBy: requestedBy ?? TerminalRequester(kind: "user", tag: nil), openedByRequest: nil,
                     follower: follower, idleClosesAt: nil)
    }

    private func model(_ info: TerminalInfo, focuses: [FollowFocusOption]? = nil) -> FollowModel {
        FollowModel(info: info, focuses: focuses ?? [core, claudia, cody])
    }

    private func following(_ tag: String, paused: Bool = false, reason: String? = nil) -> TerminalFollower {
        TerminalFollower(tag: tag, paused: paused, pauseReason: reason)
    }

    private func srgb(_ color: NSColor) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let c = color.usingColorSpace(.sRGB) ?? color
        return (c.redComponent, c.greenComponent, c.blueComponent)
    }

    private func assertSameColor(_ a: NSColor, _ b: NSColor, file: StaticString = #filePath, line: UInt = #line) {
        let x = srgb(a), y = srgb(b)
        XCTAssertEqual(x.r, y.r, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(x.g, y.g, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(x.b, y.b, accuracy: 0.01, file: file, line: line)
    }

    /// A strongly saturated colour whose hue is in the red band.
    private func looksRed(_ color: NSColor) -> Bool {
        let c = color.usingColorSpace(.sRGB) ?? color
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return s > 0.5 && (h < 0.04 || h > 0.96)
    }

    // MARK: Badge text

    func testAPaneNobodyFollowsSaysNotShared() {
        let m = model(info())
        XCTAssertEqual(m.badgeText, "Not shared")
        XCTAssertEqual(m.state, .notShared)
    }

    func testAFollowedPaneNamesTheFollowerByItsFocusLabelNotItsTag() {
        let m = model(info(follower: following("claudia-1")))
        XCTAssertEqual(m.badgeText, "Followed by Claudia")
        XCTAssertFalse(m.badgeText.contains("claudia-1"))
    }

    func testAFollowerWhoseFocusIsGoneFallsBackToItsTag() {
        let m = model(info(follower: following("gone-9")))
        XCTAssertEqual(m.badgeText, "Followed by gone-9")
    }

    func testAPausedFollowingSaysWhyItPaused() {
        XCTAssertEqual(model(info(follower: following("claudia-1", paused: true, reason: "too_much_output"))).badgeText,
                       "Paused, too much output")
        XCTAssertEqual(model(info(follower: following("claudia-1", paused: true, reason: "too_many_deliveries"))).badgeText,
                       "Paused, too many deliveries")
    }

    func testAPausedFollowingWithNoOrAnUnknownReasonJustSaysPaused() {
        XCTAssertEqual(model(info(follower: following("claudia-1", paused: true, reason: nil))).badgeText, "Paused")
        XCTAssertEqual(model(info(follower: following("claudia-1", paused: true, reason: "something_new"))).badgeText, "Paused")
    }

    func testTheBadgeDescriptionIsAWholeSentenceThatNamesTheFollowerWhileFollowed() {
        let d = model(info(follower: following("claudia-1"))).badgeDescription
        XCTAssertTrue(d.contains("Claudia"), d)
        XCTAssertFalse(d.isEmpty)
        XCTAssertFalse(model(info()).badgeDescription.isEmpty)
    }

    func testThePausedDescriptionSaysTheFollowerIsNotReceivingOutput() {
        let d = model(info(follower: following("claudia-1", paused: true, reason: "too_much_output"))).badgeDescription
        XCTAssertTrue(d.contains("Claudia"), d)
        XCTAssertTrue(d.localizedCaseInsensitiveContains("too much output"), d)
    }

    // MARK: Badge colour

    func testTheBadgeIsNeverRedInAnyStateOnAnyKindOfPane() {
        let followers: [TerminalFollower?] = [nil, following("claudia-1"), following("claudia-1", paused: true, reason: "too_much_output")]
        for kind in [TerminalKind.local, .ecs] {
            for follower in followers {
                let m = model(info(kind: kind, target: kind == .ecs ? target("production") : nil, follower: follower))
                XCTAssertFalse(looksRed(m.badgeColor), "\(kind) \(String(describing: follower))")
            }
        }
    }

    func testAFollowedBadgeIsFollowBlue() {
        assertSameColor(model(info(follower: following("claudia-1"))).badgeColor, Theme.followBlue)
    }

    func testAPausedBadgeIsAmberAndANotSharedBadgeIsMuted() {
        assertSameColor(model(info(follower: following("claudia-1", paused: true, reason: nil))).badgeColor, Theme.amber)
        assertSameColor(model(info()).badgeColor, Theme.fgMuted)
    }

    func testTheBadgeHasAMinimumWidthWideEnoughForNotShared() {
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let text = (FollowModel.notSharedText as NSString).size(withAttributes: [.font: font]).width
        XCTAssertGreaterThanOrEqual(FollowModel.badgeMinWidth, text)
    }

    // MARK: Actions

    func testARunningPaneNobodyFollowsOffersInvite() {
        XCTAssertEqual(model(info()).actions, [.invite])
    }

    func testAPaneThatIsNotRunningAndNotFollowedOffersNothing() {
        XCTAssertEqual(model(info(status: .ended)).actions, [])
    }

    func testAFollowedPaneOffersStopAndMove() {
        XCTAssertEqual(model(info(follower: following("claudia-1"))).actions, [.stop, .move])
    }

    func testAPausedPaneOffersResumeAndStop() {
        XCTAssertEqual(model(info(follower: following("claudia-1", paused: true, reason: "too_much_output"))).actions, [.resume, .stop])
    }

    func testAFollowedPaneCanStillBeStoppedAfterItEnded() {
        XCTAssertTrue(model(info(status: .ended, follower: following("claudia-1"))).actions.contains(.stop))
    }

    // MARK: Invite defaults

    func testTheInviteStartsOnTheFocusThatOwnsThePane() {
        XCTAssertEqual(model(info(tag: "cody-1")).defaultInviteTag, "cody-1")
    }

    func testTheInviteForARemotePaneAnAgentAskedForStartsOnTheAgentThatAsked() {
        let i = info(tag: "core-1", kind: .ecs, target: target("production"),
                     requestedBy: TerminalRequester(kind: "focus", tag: "claudia-1"))
        XCTAssertEqual(model(i).defaultInviteTag, "claudia-1")
    }

    func testTheInviteForARemotePaneAPersonOpenedStartsOnTheOwner() {
        let i = info(tag: "core-1", kind: .ecs, target: target("production"),
                     requestedBy: TerminalRequester(kind: "user", tag: nil))
        XCTAssertEqual(model(i).defaultInviteTag, "core-1")
    }

    func testARequesterThatIsNoLongerAFocusFallsBackToTheOwner() {
        let i = info(tag: "core-1", kind: .ecs, target: target("production"),
                     requestedBy: TerminalRequester(kind: "focus", tag: "gone-9"))
        XCTAssertEqual(model(i).defaultInviteTag, "core-1")
    }

    func testAnOwnerThatIsNotAFocusFallsBackToTheFirstFocus() {
        XCTAssertEqual(model(info(tag: "gone-9")).defaultInviteTag, "core-1")
    }

    func testMovingStartsOnAnotherFocusNotTheOneThatAlreadyFollows() {
        let m = model(info(tag: "core-1", follower: following("core-1")))
        XCTAssertEqual(m.defaultInviteTag, "claudia-1", "the owner follows, so the next focus is offered")
    }

    func testMovingAnAgentRequestedPaneSkipsTheRequesterThatFollows() {
        let i = info(tag: "core-1", kind: .ecs, target: target("production"),
                     requestedBy: TerminalRequester(kind: "focus", tag: "claudia-1"), follower: following("claudia-1"))
        XCTAssertEqual(model(i).defaultInviteTag, "core-1")
    }

    func testMovingWithOnlyOneFocusFallsBackToThatFocus() {
        let m = model(info(tag: "core-1", follower: following("core-1")), focuses: [core])
        XCTAssertEqual(m.defaultInviteTag, "core-1")
    }

    func testAFollowerThatIsNotTheDefaultDoesNotChangeTheDefault() {
        XCTAssertEqual(model(info(tag: "core-1", follower: following("cody-1"))).defaultInviteTag, "core-1")
    }

    func testWithNoFocusesThereIsNoInviteTarget() {
        let m = model(info(), focuses: [])
        XCTAssertNil(m.defaultInviteTag)
        XCTAssertNil(m.defaultSelectionTag)
        XCTAssertEqual(m.otherSelectionFocuses, [])
    }

    func testIncludingTheScreenIsOffByDefault() {
        XCTAssertFalse(FollowModel.includeScreenDefault)
        XCTAssertEqual(FollowModel.includeScreenTitle, "Include what's on screen now")
    }

    // MARK: Warning

    func testALocalPaneWarnsThatOutputGoesToTheAgentsModel() {
        XCTAssertEqual(model(info()).warning(forFocusTag: "claudia-1"), "Output will be sent to Claudia's model.")
    }

    func testAProductionPaneWarnsThatProductionOutputGoesToTheAgentsModel() {
        let m = model(info(kind: .ecs, target: target("production")))
        XCTAssertEqual(m.warning(forFocusTag: "claudia-1"), "Output from PRODUCTION will be sent to Claudia's model.")
    }

    func testAStagingPaneNamesItsOwnEnvironmentInCapitals() {
        let m = model(info(kind: .ecs, target: target("staging")))
        XCTAssertEqual(m.warning(forFocusTag: "cody-1"), "Output from STAGING will be sent to Cody's model.")
    }

    func testARemotePaneWithNoKnownTargetSaysRemote() {
        let m = model(info(kind: .ecs, target: nil))
        XCTAssertEqual(m.warning(forFocusTag: "claudia-1"), "Output from REMOTE will be sent to Claudia's model.")
    }

    func testTheWarningFollowsTheFocusPickedAndFallsBackToTheTagForAGoneFocus() {
        let m = model(info())
        XCTAssertEqual(m.warning(forFocusTag: "cody-1"), "Output will be sent to Cody's model.")
        XCTAssertEqual(m.warning(forFocusTag: "gone-9"), "Output will be sent to gone-9's model.")
    }

    // MARK: Send selection

    func testSendSelectionOffersTheOwnerFirst() {
        XCTAssertEqual(model(info(tag: "claudia-1")).defaultSelectionTag, "claudia-1")
    }

    func testSendSelectionFallsBackToTheFirstFocusWhenTheOwnerIsNotOne() {
        XCTAssertEqual(model(info(tag: "gone-9")).defaultSelectionTag, "core-1")
    }

    func testTheOtherFocusesExcludeTheDefaultAndKeepTheSidebarOrder() {
        XCTAssertEqual(model(info(tag: "claudia-1")).otherSelectionFocuses, [core, cody])
        XCTAssertEqual(model(info(tag: "gone-9")).otherSelectionFocuses, [claudia, cody])
    }

    func testSendSelectionTitleNamesTheFocusByItsLabel() {
        XCTAssertEqual(FollowModel.sendSelectionTitle(to: claudia), "Send selection to Claudia")
    }
}
