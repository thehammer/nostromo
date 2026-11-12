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

    func testASelectionOverTheDaemonsLimitIsTooLargeAndOneAtTheLimitIsNot() {
        XCTAssertEqual(FollowModel.selectionLimitBytes, 16 * 1024)
        XCTAssertFalse(FollowModel.selectionIsTooLarge(String(repeating: "a", count: 16 * 1024)))
        XCTAssertTrue(FollowModel.selectionIsTooLarge(String(repeating: "a", count: 16 * 1024 + 1)))
        // Bytes, not characters: 8193 two-byte characters are over.
        XCTAssertTrue(FollowModel.selectionIsTooLarge(String(repeating: "é", count: 8 * 1024 + 1)))
    }

    func testTheSendSelectionTooltipAndRefusalSayWhatTheDaemonDoes() {
        XCTAssertTrue(FollowModel.sendSelectionTooltip.contains("redacts"))
        XCTAssertTrue(FollowModel.sendSelectionTooltip.contains("caps"))
        XCTAssertTrue(FollowModel.selectionTooLargeMessage.contains("too large"))
    }

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

    // MARK: Staging only (S3b): the badge
    //
    // A staging-only follower may stage commands for the person to place but is sent no output. The badge says
    // so in its own words and its own (neutral) colour: it is neither "Followed" (blue: output goes to a model)
    // nor "Paused" (amber), and it is never red.

    private func stagingOnly(_ tag: String = "claudia-1", paused: Bool = false, reason: String? = nil) -> TerminalFollower {
        TerminalFollower(tag: tag, paused: paused, pauseReason: reason, mode: "staging_only")
    }

    /// A model for a build whose popover offers the staging-only choice (unless `offers` is false).
    private func offering(_ info: TerminalInfo, focuses: [FollowFocusOption]? = nil, offers: Bool = true) -> FollowModel {
        FollowModel(info: info, focuses: focuses ?? [core, claudia, cody], offersStagingOnly: offers)
    }

    private func assertDifferentColor(_ a: NSColor, _ b: NSColor, file: StaticString = #filePath, line: UInt = #line) {
        let x = srgb(a), y = srgb(b)
        let apart = abs(x.r - y.r) > 0.01 || abs(x.g - y.g) > 0.01 || abs(x.b - y.b) > 0.01
        XCTAssertTrue(apart, "the two colours are the same", file: file, line: line)
    }

    func testAStagingOnlyFollowerIsItsOwnStateAndTheBadgeNamesIt() {
        let m = model(info(follower: stagingOnly()))
        XCTAssertEqual(m.state, .stagingOnly(by: "Claudia"))
        XCTAssertEqual(m.badgeText, "Staging only: Claudia")
    }

    func testAStagingOnlyBadgeFallsBackToTheTagWhenTheFocusIsGone() {
        XCTAssertEqual(model(info(follower: stagingOnly("gone-9"))).badgeText, "Staging only: gone-9")
    }

    func testAStagingOnlyFollowerIsNeverPausedEvenIfThePausedFlagIsReported() {
        let m = model(info(follower: stagingOnly(paused: true, reason: "too_much_output")))
        XCTAssertEqual(m.state, .stagingOnly(by: "Claudia"))
        XCTAssertEqual(m.badgeText, "Staging only: Claudia")
        XCTAssertEqual(m.actions, [.stop, .move], "no Resume: nothing is being delivered to pause")
    }

    func testAnUnknownFollowModeCountsAsAFullFollow() {
        for mode in [nil, "future_mode", "STAGING_ONLY", ""] as [String?] {
            let m = model(info(follower: TerminalFollower(tag: "claudia-1", paused: false, pauseReason: nil, mode: mode)))
            XCTAssertEqual(m.state, .followed(by: "Claudia"), "mode \(String(describing: mode))")
            XCTAssertEqual(m.badgeText, "Followed by Claudia")
            assertSameColor(m.badgeColor, Theme.followBlue)
        }
    }

    func testAStagingOnlyBadgeIsMutedNotFollowBlueNotAmberAndNeverRed() {
        for kind in [TerminalKind.local, .ecs] {
            let m = model(info(kind: kind, target: kind == .ecs ? target("production") : nil, follower: stagingOnly()))
            assertSameColor(m.badgeColor, Theme.fgMuted)
            assertDifferentColor(m.badgeColor, Theme.followBlue)
            assertDifferentColor(m.badgeColor, Theme.amber)
            XCTAssertFalse(looksRed(m.badgeColor), "\(kind)")
        }
    }

    func testAStagingOnlyBadgeSaysTheOutputIsNotSentToTheAgentsModel() {
        let m = model(info(follower: stagingOnly()))
        XCTAssertEqual(m.badgeDescription,
                       "Claudia can stage commands for you to place. This terminal's output is not sent to Claudia's model.")
    }

    func testAStagingOnlyPaneOffersStopAndMove() {
        XCTAssertEqual(model(info(follower: stagingOnly())).actions, [.stop, .move])
        XCTAssertEqual(model(info(status: .ended, follower: stagingOnly())).actions, [.stop, .move])
    }

    func testAStagingOnlyFollowerIsStillShownWhenThePopoverDoesNotOfferTheChoice() {
        // What the badge says is the daemon's truth; whether a person can pick it is a separate gate.
        let m = offering(info(follower: stagingOnly()), offers: false)
        XCTAssertEqual(m.state, .stagingOnly(by: "Claudia"))
        XCTAssertEqual(m.badgeText, "Staging only: Claudia")
    }

    func testTheStagingOnlyChoiceIsNotOfferedUnlessAskedFor() {
        XCTAssertFalse(model(info()).offersStagingOnly)
        XCTAssertFalse(FollowModel(info: info(), focuses: [core]).offersStagingOnly)
        XCTAssertTrue(offering(info()).offersStagingOnly)
        XCTAssertFalse(offering(info(), offers: false).offersStagingOnly)
    }

    // MARK: Staging only (S3b): the invite popover

    func testTheModeGroupAndItsTwoChoicesHaveTheirWords() {
        XCTAssertEqual(FollowModel.modeGroupTitle, "What the agent gets")
        XCTAssertEqual(FollowModel.outputOptionTitle, "Output: it reads this terminal")
        XCTAssertEqual(FollowModel.stagingOnlyOptionTitle, "Staging only: it proposes commands and sees no output")
        XCTAssertNotEqual(FollowModel.InviteMode.output, FollowModel.InviteMode.stagingOnly)
    }

    func testWithNobodyFollowingEveryFocusIsOfferedInBothModes() {
        let m = offering(info())
        XCTAssertEqual(m.inviteFocuses(for: .output), [core, claudia, cody])
        XCTAssertEqual(m.inviteFocuses(for: .stagingOnly), [core, claudia, cody])
    }

    func testAFullFollowerIsLeftOutOfOutputButOfferedStagingOnly() {
        let m = offering(info(follower: following("claudia-1")))
        XCTAssertEqual(m.inviteFocuses(for: .output), [core, cody], "moving the same mode to the same focus is no change")
        XCTAssertEqual(m.inviteFocuses(for: .stagingOnly), [core, claudia, cody], "it may be changed to staging only")
    }

    func testAStagingOnlyFollowerIsOfferedOutputButLeftOutOfStagingOnly() {
        let m = offering(info(follower: stagingOnly()))
        XCTAssertEqual(m.inviteFocuses(for: .output), [core, claudia, cody], "it may be changed to output")
        XCTAssertEqual(m.inviteFocuses(for: .stagingOnly), [core, cody])
    }

    func testAPausedFullFollowerIsTreatedAsAFullFollower() {
        let m = offering(info(follower: following("claudia-1", paused: true, reason: "too_much_output")))
        XCTAssertEqual(m.inviteFocuses(for: .output), [core, cody])
        XCTAssertEqual(m.inviteFocuses(for: .stagingOnly), [core, claudia, cody])
    }

    func testAFollowerWhoseModeIsUnknownIsTreatedAsFullWhenChoosingWhatToOffer() {
        let m = offering(info(follower: TerminalFollower(tag: "claudia-1", paused: false, pauseReason: nil, mode: "future_mode")))
        XCTAssertEqual(m.inviteFocuses(for: .output), [core, cody])
        XCTAssertEqual(m.inviteFocuses(for: .stagingOnly), [core, claudia, cody])
    }

    func testWithoutTheStagingOnlyChoiceTheFollowerIsLeftOutWhateverTheMode() {
        for follower in [following("claudia-1"), stagingOnly()] {
            let m = offering(info(follower: follower), offers: false)
            XCTAssertEqual(m.inviteFocuses(for: .output), [core, cody])
            XCTAssertEqual(m.inviteFocuses(for: .stagingOnly), [core, cody])
            XCTAssertEqual(m.inviteFocuses(for: .output), m.inviteFocuses)
        }
    }

    func testTheExistingInviteFocusesStayTheOutputModeListForAFullFollower() {
        let full = offering(info(follower: following("claudia-1")))
        XCTAssertEqual(full.inviteFocuses, [core, cody])
        XCTAssertEqual(full.inviteFocuses, full.inviteFocuses(for: .output))
        XCTAssertEqual(offering(info()).inviteFocuses, [core, claudia, cody])
    }

    func testTheHeadingSaysChangeWhatTheAgentGetsOnlyForTheFollowerInTheOtherMode() {
        let full = offering(info(follower: following("claudia-1")))
        XCTAssertEqual(full.inviteHeading(forTag: "claudia-1", mode: .stagingOnly), "Change what Claudia gets")
        XCTAssertEqual(full.inviteHeading(forTag: "claudia-1", mode: .output), "Move this terminal to another agent")
        XCTAssertEqual(full.inviteHeading(forTag: "cody-1", mode: .stagingOnly), "Move this terminal to another agent")
        XCTAssertEqual(full.inviteHeading(forTag: nil, mode: .stagingOnly), "Move this terminal to another agent")

        let staging = offering(info(follower: stagingOnly()))
        XCTAssertEqual(staging.inviteHeading(forTag: "claudia-1", mode: .output), "Change what Claudia gets")
        XCTAssertEqual(staging.inviteHeading(forTag: "claudia-1", mode: .stagingOnly), "Move this terminal to another agent")
        XCTAssertEqual(staging.inviteHeading(forTag: "cody-1", mode: .output), "Move this terminal to another agent")
    }

    func testTheHeadingForAPaneNobodyFollowsIsTheSameInEitherMode() {
        let m = offering(info())
        for mode in [FollowModel.InviteMode.output, .stagingOnly] {
            XCTAssertEqual(m.inviteHeading(forTag: "claudia-1", mode: mode), "Let an agent follow this terminal")
            XCTAssertEqual(m.inviteHeading(forTag: nil, mode: mode), "Let an agent follow this terminal")
        }
        XCTAssertEqual(m.inviteHeading, "Let an agent follow this terminal")
    }

    func testTheExistingHeadingPropertyIsUnchanged() {
        XCTAssertEqual(offering(info(follower: following("claudia-1"))).inviteHeading, "Move this terminal to another agent")
        XCTAssertEqual(offering(info(follower: stagingOnly())).inviteHeading, "Move this terminal to another agent")
    }

    func testTheChangeHeadingNamesTheFocusByItsLabelNotItsTag() {
        let m = offering(info(follower: following("claudia-1")), focuses: [core, FollowFocusOption(tag: "claudia-1", name: "Claudia the Great")])
        XCTAssertEqual(m.inviteHeading(forTag: "claudia-1", mode: .stagingOnly), "Change what Claudia the Great gets")
    }

    func testTheOutputWarningIsUnchangedByTheChoiceBeingOffered() {
        let local = offering(info())
        XCTAssertEqual(local.warning(forFocusTag: "claudia-1"), "Output will be sent to Claudia's model.")
        XCTAssertEqual(local.warning(forFocusTag: "claudia-1", mode: .output), "Output will be sent to Claudia's model.")
        let remote = offering(info(kind: .ecs, target: target("production")))
        XCTAssertEqual(remote.warning(forFocusTag: "claudia-1", mode: .output), "Output from PRODUCTION will be sent to Claudia's model.")
    }

    func testAStagingOnlyWarningOnALocalPaneSaysNoOutputIsSent() {
        let m = offering(info())
        XCTAssertEqual(m.warning(forFocusTag: "claudia-1", mode: .stagingOnly),
                       "Claudia can stage commands for this terminal. Its output will NOT be sent to Claudia's model.")
        XCTAssertEqual(m.warning(forFocusTag: "cody-1", mode: .stagingOnly),
                       "Cody can stage commands for this terminal. Its output will NOT be sent to Cody's model.")
        XCTAssertEqual(m.warning(forFocusTag: "gone-9", mode: .stagingOnly),
                       "gone-9 can stage commands for this terminal. Its output will NOT be sent to gone-9's model.")
    }

    func testAStagingOnlyWarningOnARemotePaneNamesTheEnvironmentAndSaysThePersonPlacesEachCommand() {
        let production = offering(info(kind: .ecs, target: target("production")))
        XCTAssertEqual(production.warning(forFocusTag: "claudia-1", mode: .stagingOnly),
                       "Output from PRODUCTION will NOT be sent to Claudia's model. Claudia can stage commands; you place and run each one.")
        let staging = offering(info(kind: .ecs, target: target("staging")))
        XCTAssertEqual(staging.warning(forFocusTag: "cody-1", mode: .stagingOnly),
                       "Output from STAGING will NOT be sent to Cody's model. Cody can stage commands; you place and run each one.")
        let unknown = offering(info(kind: .ecs, target: nil))
        XCTAssertEqual(unknown.warning(forFocusTag: "claudia-1", mode: .stagingOnly),
                       "Output from REMOTE will NOT be sent to Claudia's model. Claudia can stage commands; you place and run each one.")
    }

    func testTheInviteButtonIsReadAloudForTheModeChosen() {
        let m = offering(info())
        XCTAssertEqual(m.inviteAccessibilityLabel(mode: .output), "Invite the chosen agent to follow this terminal")
        XCTAssertEqual(m.inviteAccessibilityLabel(mode: .stagingOnly), "Invite the chosen agent to stage commands only, with no output")
    }

    // MARK: Staging only (S3b): the Send selection label
    //
    // Send selection hands the selected text to an agent's model. To a staging-only follower that is output it
    // is deliberately not sent, so its menu item says so, in the title, the tooltip and the spoken label. Every
    // other item is exactly what it was.

    private func sendItem(_ m: FollowModel, _ option: FollowFocusOption, enabled: Bool = true,
                          target: AnyObject? = nil, action: Selector = Selector(("sendSelectionTapped:"))) -> NSMenuItem {
        m.sendSelectionMenuItem(for: option, enabled: enabled, target: target, action: action)
    }

    private func assertPlainSendItem(_ item: NSMenuItem, _ option: FollowFocusOption, _ note: String = "",
                                     file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(item.title, "Send selection to \(option.name)", note, file: file, line: line)
        XCTAssertEqual(item.toolTip, FollowModel.sendSelectionTooltip, note, file: file, line: line)
        XCTAssertEqual(item.accessibilityLabel(), item.title, note, file: file, line: line)
    }

    func testTheSendSelectionItemOfAStagingOnlyFollowerSaysItGivesItOutput() {
        let m = model(info(follower: stagingOnly()))
        let item = sendItem(m, claudia)
        XCTAssertEqual(item.title, "Send selection to Claudia (staging only: this gives it output)")
        let tooltip = "Claudia follows this terminal staging only and is not sent its output. "
            + "Sending this selection gives Claudia's model text it would not otherwise see. " + FollowModel.sendSelectionTooltip
        XCTAssertEqual(item.toolTip, tooltip)
        XCTAssertEqual(item.accessibilityLabel(), item.title + ". " + tooltip)
    }

    func testTheStagingOnlyLabelNamesTheFocusByItsLabelNotItsTag() {
        let great = FollowFocusOption(tag: "claudia-1", name: "Claudia the Great")
        let item = sendItem(model(info(follower: stagingOnly()), focuses: [core, great, cody]), great)
        XCTAssertEqual(item.title, "Send selection to Claudia the Great (staging only: this gives it output)")
        XCTAssertTrue(item.toolTip?.hasPrefix("Claudia the Great follows this terminal staging only") ?? false, item.toolTip ?? "")
        XCTAssertFalse(item.title.contains("claudia-1"))
    }

    func testTheStagingOnlyLabelShowsWhateverTheBuildOffersAndWhateverThePausedFlagSays() {
        let followers = [stagingOnly(), stagingOnly(paused: true, reason: "too_much_output")]
        for follower in followers {
            for offers in [true, false] {
                let item = sendItem(offering(info(follower: follower), offers: offers), claudia)
                XCTAssertTrue(item.title.hasSuffix("(staging only: this gives it output)"), "offers \(offers): \(item.title)")
            }
        }
    }

    func testTheSendSelectionItemOfAFullFollowerOrNoFollowerHasNoStagingOnlyLabel() {
        let followers: [(String, TerminalFollower?)] = [
            ("nobody follows", nil),
            ("a full follower", following("claudia-1")),
            ("a paused full follower", following("claudia-1", paused: true, reason: "too_much_output")),
        ]
        for (note, follower) in followers {
            let m = model(info(follower: follower))
            for option in [core, claudia, cody] { assertPlainSendItem(sendItem(m, option), option, "\(note), \(option.name)") }
        }
    }

    func testAFollowerWhoseModeIsUnknownIsAFullFollowerForTheSendSelectionLabel() {
        for mode in [nil, "future_mode", "STAGING_ONLY", ""] as [String?] {
            let m = model(info(follower: TerminalFollower(tag: "claudia-1", paused: false, pauseReason: nil, mode: mode)))
            assertPlainSendItem(sendItem(m, claudia), claudia, "mode \(String(describing: mode))")
        }
    }

    func testOnlyTheStagingOnlyFollowersItemIsLabelledTheOtherFocusesAreUnchanged() {
        let m = model(info(follower: stagingOnly()))
        assertPlainSendItem(sendItem(m, core), core)
        assertPlainSendItem(sendItem(m, cody), cody)
        XCTAssertNotEqual(sendItem(m, claudia).title, FollowModel.sendSelectionTitle(to: claudia))
    }

    func testTheSendSelectionItemPassesThroughItsTargetActionTagAndEnabledFlag() {
        let target = NSObject()
        let action = Selector(("sendSelectionTapped:"))
        for follower in [nil, stagingOnly()] as [TerminalFollower?] {
            let m = model(info(follower: follower))
            for enabled in [true, false] {
                let item = sendItem(m, claudia, enabled: enabled, target: target, action: action)
                XCTAssertEqual(item.representedObject as? String, "claudia-1")
                XCTAssertTrue(item.target === target)
                XCTAssertEqual(item.action, action)
                XCTAssertEqual(item.isEnabled, enabled, "staging only: \(follower != nil), enabled: \(enabled)")
            }
        }
    }

    // MARK: Staging only (S3b): what the invite form opens on

    func testAPaneWithAStagingOnlyFollowerOpensTheInviteFormOnStagingOnly() {
        XCTAssertEqual(offering(info(follower: stagingOnly())).defaultInviteMode, .stagingOnly)
        XCTAssertEqual(offering(info(follower: stagingOnly(paused: true, reason: "too_much_output"))).defaultInviteMode, .stagingOnly)
        XCTAssertEqual(offering(info(kind: .ecs, target: target("production"), follower: stagingOnly())).defaultInviteMode, .stagingOnly)
    }

    func testEveryOtherPaneOpensTheInviteFormOnOutput() {
        XCTAssertEqual(offering(info()).defaultInviteMode, .output, "nobody follows")
        XCTAssertEqual(offering(info(kind: .ecs, target: target("production"))).defaultInviteMode, .output, "a remote pane nobody follows")
        XCTAssertEqual(offering(info(follower: following("claudia-1"))).defaultInviteMode, .output, "a full follower")
        XCTAssertEqual(offering(info(follower: following("claudia-1", paused: true, reason: "too_much_output"))).defaultInviteMode, .output,
                       "a paused full follower")
        XCTAssertEqual(offering(info(follower: TerminalFollower(tag: "claudia-1", paused: false, pauseReason: nil, mode: "future_mode"))).defaultInviteMode,
                       .output, "an unknown mode is a full follow")
    }

    func testWithoutTheStagingOnlyChoiceTheFormOpensOnOutputWhateverTheFollower() {
        XCTAssertEqual(offering(info(follower: stagingOnly()), offers: false).defaultInviteMode, .output)
        XCTAssertEqual(model(info(follower: stagingOnly())).defaultInviteMode, .output)
    }
}

// MARK: - The Follow popover (S3b)

// `FollowControlView`: when the build offers the staging-only choice, the invite form has a "What the agent
// gets" group with two radios (Output, the default, and Staging only). Choosing staging only changes what the
// form says and what Invite sends: one `follow_invite_staging_only` frame and never a `follow_invite` (that
// frame starts a full follow). Both radios and Invite answer to a person's gesture only (`TerminalInputGuard`
// asked with `eventSource()`): a synthetic change is undone and reported, and Invite sends nothing.
//
// The view is put in an off-screen window (a control must be in a window to be permitted); a "person" is a
// real-typed mouse event in that window, a "synthetic" one is nil or app-control-stamped.

final class FollowControlViewTests: MouseQueueTestCase {

    private let core = FollowFocusOption(tag: "core-1", name: "Core")
    private let claudia = FollowFocusOption(tag: "claudia-1", name: "Claudia")
    private let cody = FollowFocusOption(tag: "cody-1", name: "Cody")

    private final class Recorder {
        var messages: [TerminalClientMessage] = []
        var closeCount = 0
        var now = Date(timeIntervalSince1970: 1_000_000)
    }

    private struct Rig {
        let view: FollowControlView
        let recorder: Recorder
        let window: NSWindow
        let model: FollowModel

        /// A person's click: a real-typed mouse event in the popover's window, fresh each time it is asked for.
        func person() {
            let window = window
            view.eventSource = { GestureFixtures.mouse(.leftMouseUp, in: window) }
        }
        /// Something other than a person: no event (an Accessibility press) or an app-control event.
        func synthetic() { view.eventSource = { nil } }
        func stamped() {
            let window = window
            view.eventSource = { try? GestureFixtures.marked(GestureFixtures.mouse(.leftMouseUp, in: window)) }
        }
        /// Moves the store's clock past its once-a-second limit on repeated refusal reports.
        func letTimePass() { recorder.now = recorder.now.addingTimeInterval(10) }
    }

    private func makeRig(follower: TerminalFollower? = nil, ownerTag: String = "claudia-1", kind: TerminalKind = .local,
                         environment: String = "production", offersStagingOnly: Bool = true,
                         status: TerminalStatus = .running, focuses: [FollowFocusOption]? = nil) -> Rig {
        let target = kind == .ecs ? TerminalTarget(project: "admin-portal", environment: environment, service: "scheduler", shellType: "shell") : nil
        let info = TerminalInfo(terminalId: "t1", tag: ownerTag, paneId: "terminal-a", kind: kind, label: "Terminal", cwd: nil, target: target,
                                status: status, exitCode: nil, endedReason: nil, cols: 80, rows: 24,
                                requestedBy: TerminalRequester(kind: "user", tag: nil), openedByRequest: nil,
                                follower: follower, idleClosesAt: nil)
        let model = FollowModel(info: info, focuses: focuses ?? [core, claudia, cody], offersStagingOnly: offersStagingOnly)
        let recorder = Recorder()
        let store = TerminalSessionStore(now: { recorder.now }, transport: { recorder.messages.append($0) })
        let view = FollowControlView(model: model, store: store, closePopover: { recorder.closeCount += 1 })
        let window = GestureFixtures.offscreenWindow(size: NSSize(width: 600, height: 900))
        addTeardownBlock { window.close() }
        window.contentView!.addSubview(view)
        view.layoutSubtreeIfNeeded()
        return Rig(view: view, recorder: recorder, window: window, model: model)
    }

    // MARK: Finding things

    private func allViews(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { allViews($0) }
    }

    private func find(_ id: String, in rig: Rig) -> NSView? {
        allViews(rig.view).first { $0.accessibilityIdentifier() == id }
    }

    private func button(_ id: String, in rig: Rig, file: StaticString = #filePath, line: UInt = #line) throws -> NSButton {
        try XCTUnwrap(find(id, in: rig) as? NSButton, "no button \(id)", file: file, line: line)
    }

    private func text(_ id: String, in rig: Rig, file: StaticString = #filePath, line: UInt = #line) throws -> String {
        try XCTUnwrap(find(id, in: rig) as? NSTextField, "no label \(id)", file: file, line: line).stringValue
    }

    private func picker(in rig: Rig, file: StaticString = #filePath, line: UInt = #line) throws -> NSPopUpButton {
        try XCTUnwrap(find("terminal-follow-picker", in: rig) as? NSPopUpButton, "no picker", file: file, line: line)
    }

    private func pickedTag(in rig: Rig) throws -> String? {
        try picker(in: rig).selectedItem?.representedObject as? String
    }

    private let outputId = "terminal-follow-mode-output"
    private let stagingId = "terminal-follow-mode-staging-only"

    /// A person chooses a radio: the click flips it and runs its action under their gesture.
    private func choose(_ id: String, in rig: Rig, file: StaticString = #filePath, line: UInt = #line) throws {
        rig.person()
        try button(id, in: rig, file: file, line: line).performClick(nil)
    }

    /// A person picks `name` in the picker (the choice runs the picker's action under their gesture).
    private func pick(_ name: String, in rig: Rig, file: StaticString = #filePath, line: UInt = #line) throws {
        rig.person()
        let popup = try picker(in: rig, file: file, line: line)
        popup.selectItem(withTitle: name)
        XCTAssertEqual(popup.titleOfSelectedItem, name, "\(name) is not in the picker", file: file, line: line)
        popup.sendAction(popup.action, to: popup.target)
    }

    private func invite(in rig: Rig, file: StaticString = #filePath, line: UInt = #line) throws {
        try button("terminal-follow-invite", in: rig, file: file, line: line).performClick(nil)
    }

    private func refusals(_ rig: Rig) -> [TerminalClientMessage] {
        rig.recorder.messages.filter { $0 == .refusalReport(terminalId: "t1", op: .followInvite, channel: "app_control") }
    }

    private func inviteFrames(_ rig: Rig) -> [TerminalClientMessage] {
        rig.recorder.messages.filter {
            switch $0 {
            case .followInvite, .followInviteStagingOnly: return true
            default: return false
            }
        }
    }

    /// The form of a pane nobody follows, with the staging-only choice offered.
    private func offeredForm() -> Rig { makeRig() }

    /// Press Move to… on a pane someone follows, so the invite form is showing.
    private func openMove(_ rig: Rig) throws {
        rig.person()
        try button("terminal-follow-move", in: rig).performClick(nil)
        _ = try picker(in: rig)
    }

    // MARK: (a) The choice is absent unless offered

    func testWithoutTheStagingOnlyChoiceTheFormHasNoModeViewsAndInviteSendsAFullFollowInvite() throws {
        let rig = makeRig(offersStagingOnly: false)
        let modeViews = allViews(rig.view).filter { $0.accessibilityIdentifier().hasPrefix("terminal-follow-mode") }
        XCTAssertTrue(modeViews.isEmpty, "\(modeViews.map { $0.accessibilityIdentifier() })")
        XCTAssertEqual(try button("terminal-follow-invite", in: rig).accessibilityLabel(), "Invite the chosen agent to follow this terminal")
        XCTAssertEqual(try text("terminal-follow-heading", in: rig), "Let an agent follow this terminal")
        XCTAssertEqual(try text("terminal-follow-warning", in: rig), "Output will be sent to Claudia's model.")

        rig.person()
        try invite(in: rig)
        XCTAssertEqual(rig.recorder.messages, [.followInvite(terminalId: "t1", followerTag: "claudia-1", includeScreen: false)])
        XCTAssertEqual(rig.recorder.closeCount, 1)
    }

    func testWithoutTheStagingOnlyChoiceAFullFollowerIsStillNotOfferedInThePicker() throws {
        let rig = makeRig(follower: TerminalFollower(tag: "claudia-1", paused: false, pauseReason: nil), ownerTag: "core-1",
                          offersStagingOnly: false)
        try openMove(rig)
        XCTAssertEqual(try picker(in: rig).itemTitles, ["Core", "Cody"])
        XCTAssertNil(find(outputId, in: rig))
        XCTAssertNil(find(stagingId, in: rig))
    }

    // MARK: (b) Choosing what the agent gets

    func testWhenOfferedTheFormShowsTheModeGroupWithOutputChosenByDefault() throws {
        let rig = offeredForm()
        XCTAssertEqual(try text("terminal-follow-mode-title", in: rig), FollowModel.modeGroupTitle)
        let output = try button(outputId, in: rig), staging = try button(stagingId, in: rig)
        XCTAssertEqual(output.title, FollowModel.outputOptionTitle)
        XCTAssertEqual(staging.title, FollowModel.stagingOnlyOptionTitle)
        XCTAssertEqual(output.state, .on)
        XCTAssertEqual(staging.state, .off)
        XCTAssertEqual(try text("terminal-follow-warning", in: rig), "Output will be sent to Claudia's model.")
        XCTAssertEqual(try button("terminal-follow-invite", in: rig).accessibilityLabel(),
                       rig.model.inviteAccessibilityLabel(mode: .output))
        XCTAssertEqual(try button("terminal-follow-include-screen", in: rig).state, .off)
        XCTAssertTrue(try button("terminal-follow-include-screen", in: rig).isEnabled)
        XCTAssertTrue(rig.recorder.messages.isEmpty, "opening the form sends nothing")
    }

    func testChoosingStagingOnlyChangesTheWarningTheScreenBoxAndTheInviteLabel() throws {
        let rig = offeredForm()
        try choose(stagingId, in: rig)

        XCTAssertEqual(try button(stagingId, in: rig).state, .on)
        XCTAssertEqual(try button(outputId, in: rig).state, .off)
        XCTAssertEqual(try text("terminal-follow-warning", in: rig),
                       "Claudia can stage commands for this terminal. Its output will NOT be sent to Claudia's model.")
        XCTAssertEqual(try text("terminal-follow-warning", in: rig), rig.model.warning(forFocusTag: "claudia-1", mode: .stagingOnly))
        let screen = try button("terminal-follow-include-screen", in: rig)
        XCTAssertEqual(screen.state, .off)
        XCTAssertFalse(screen.isEnabled, "there is no output to include")
        XCTAssertEqual(try button("terminal-follow-invite", in: rig).accessibilityLabel(),
                       "Invite the chosen agent to stage commands only, with no output")
        XCTAssertTrue(rig.recorder.messages.isEmpty, "choosing a mode sends nothing")
        XCTAssertEqual(rig.recorder.closeCount, 0)
    }

    func testAScreenBoxThatWasOnIsOffAndDisabledOnceStagingOnlyIsChosen() throws {
        let rig = offeredForm()
        try button("terminal-follow-include-screen", in: rig).state = .on
        try choose(stagingId, in: rig)
        let screen = try button("terminal-follow-include-screen", in: rig)
        XCTAssertEqual(screen.state, .off)
        XCTAssertFalse(screen.isEnabled)
    }

    func testStagingOnlyRemotePaneWarnsThatProductionOutputIsNotSent() throws {
        let rig = makeRig(kind: .ecs, environment: "production")
        XCTAssertEqual(try text("terminal-follow-warning", in: rig), "Output from PRODUCTION will be sent to Claudia's model.")
        try choose(stagingId, in: rig)
        XCTAssertEqual(try text("terminal-follow-warning", in: rig),
                       "Output from PRODUCTION will NOT be sent to Claudia's model. Claudia can stage commands; you place and run each one.")
    }

    func testInvitingWithStagingOnlyChosenSendsOneStagingOnlyInviteAndNoFullFollowInvite() throws {
        let rig = offeredForm()
        try choose(stagingId, in: rig)
        rig.person()
        try invite(in: rig)
        XCTAssertEqual(rig.recorder.messages, [.followInviteStagingOnly(terminalId: "t1", followerTag: "claudia-1")])
        XCTAssertFalse(rig.recorder.messages.contains { if case .followInvite = $0 { return true } else { return false } },
                       "a full follow must never be sent for a staging-only choice")
        XCTAssertEqual(rig.recorder.closeCount, 1)
    }

    func testInvitingForTheFocusPickedWithStagingOnlyNamesThatFocus() throws {
        let rig = offeredForm()
        try choose(stagingId, in: rig)
        try pick("Cody", in: rig)
        XCTAssertEqual(try text("terminal-follow-warning", in: rig),
                       "Cody can stage commands for this terminal. Its output will NOT be sent to Cody's model.")
        rig.person()
        try invite(in: rig)
        XCTAssertEqual(rig.recorder.messages, [.followInviteStagingOnly(terminalId: "t1", followerTag: "cody-1")])
    }

    func testChoosingBackToOutputSendsAFullFollowInviteAgain() throws {
        let rig = offeredForm()
        try choose(stagingId, in: rig)
        try choose(outputId, in: rig)
        XCTAssertEqual(try button(outputId, in: rig).state, .on)
        XCTAssertEqual(try button(stagingId, in: rig).state, .off)
        XCTAssertEqual(try text("terminal-follow-warning", in: rig), "Output will be sent to Claudia's model.")
        XCTAssertTrue(try button("terminal-follow-include-screen", in: rig).isEnabled)
        XCTAssertEqual(try button("terminal-follow-invite", in: rig).accessibilityLabel(), "Invite the chosen agent to follow this terminal")

        rig.person()
        try invite(in: rig)
        XCTAssertEqual(rig.recorder.messages, [.followInvite(terminalId: "t1", followerTag: "claudia-1", includeScreen: false)])
    }

    func testInvitingWithTheDefaultOutputChoiceIsTodaysFollowInvite() throws {
        let rig = offeredForm()
        rig.person()
        try invite(in: rig)
        XCTAssertEqual(rig.recorder.messages, [.followInvite(terminalId: "t1", followerTag: "claudia-1", includeScreen: false)])
    }

    // MARK: A pane nobody follows defaults to Output, remote panes included

    func testARemotePaneNobodyFollowsDefaultsToOutputAndInviteSendsAFullFollowInvite() throws {
        for environment in ["production", "staging"] {
            let rig = makeRig(kind: .ecs, environment: environment, offersStagingOnly: true)
            let token = environment.uppercased()
            XCTAssertEqual(try button(outputId, in: rig).state, .on, environment)
            XCTAssertEqual(try button(stagingId, in: rig).state, .off, environment)
            XCTAssertEqual(try text("terminal-follow-warning", in: rig), "Output from \(token) will be sent to Claudia's model.")
            XCTAssertEqual(try button("terminal-follow-include-screen", in: rig).state, .off)

            rig.person()
            try invite(in: rig)
            XCTAssertEqual(rig.recorder.messages, [.followInvite(terminalId: "t1", followerTag: "claudia-1", includeScreen: false)], environment)
            XCTAssertFalse(rig.recorder.messages.contains { if case .followInviteStagingOnly = $0 { return true } else { return false } })
            XCTAssertEqual(rig.recorder.closeCount, 1)
        }
    }

    func testARemotePaneWhereTheDaemonDoesNotOfferStagingOnlyAlsoSendsAFullFollowInvite() throws {
        let rig = makeRig(kind: .ecs, environment: "production", offersStagingOnly: false)
        XCTAssertNil(find(outputId, in: rig))
        XCTAssertNil(find(stagingId, in: rig))
        XCTAssertEqual(try text("terminal-follow-warning", in: rig), "Output from PRODUCTION will be sent to Claudia's model.")
        rig.person()
        try invite(in: rig)
        XCTAssertEqual(rig.recorder.messages, [.followInvite(terminalId: "t1", followerTag: "claudia-1", includeScreen: false)])
    }

    // MARK: (c) A synthetic change of mode does nothing

    func testASyntheticChoiceOfStagingOnlyIsUndoneAndReported() throws {
        for makeSynthetic in [{ (rig: Rig) in rig.synthetic() }, { (rig: Rig) in rig.stamped() }] {
            let rig = offeredForm()
            makeSynthetic(rig)
            try button(stagingId, in: rig).performClick(nil)

            XCTAssertEqual(try button(outputId, in: rig).state, .on, "the previous choice is restored")
            XCTAssertEqual(try button(stagingId, in: rig).state, .off)
            XCTAssertEqual(try text("terminal-follow-warning", in: rig), "Output will be sent to Claudia's model.")
            XCTAssertTrue(try button("terminal-follow-include-screen", in: rig).isEnabled)
            XCTAssertEqual(try button("terminal-follow-invite", in: rig).accessibilityLabel(), "Invite the chosen agent to follow this terminal")
            XCTAssertEqual(rig.recorder.messages, [.refusalReport(terminalId: "t1", op: .followInvite, channel: "app_control")],
                           "no invite frame, exactly one refusal report")
            XCTAssertEqual(rig.recorder.closeCount, 0)
        }
    }

    func testASyntheticChoiceBackToOutputLeavesStagingOnlyChosenAndIsReported() throws {
        let rig = offeredForm()
        try choose(stagingId, in: rig)
        rig.synthetic()
        try button(outputId, in: rig).performClick(nil)

        XCTAssertEqual(try button(stagingId, in: rig).state, .on)
        XCTAssertEqual(try button(outputId, in: rig).state, .off)
        XCTAssertEqual(try text("terminal-follow-warning", in: rig), rig.model.warning(forFocusTag: "claudia-1", mode: .stagingOnly))
        XCTAssertFalse(try button("terminal-follow-include-screen", in: rig).isEnabled)
        XCTAssertEqual(rig.recorder.messages, [.refusalReport(terminalId: "t1", op: .followInvite, channel: "app_control")])
    }

    func testARefusedModeChangeStillLetsAPersonChangeItNext() throws {
        let rig = offeredForm()
        rig.synthetic()
        try button(stagingId, in: rig).performClick(nil)
        rig.letTimePass()
        try choose(stagingId, in: rig)
        XCTAssertEqual(try button(stagingId, in: rig).state, .on)
        XCTAssertEqual(refusals(rig).count, 1)
    }

    // MARK: (e) Invite itself needs a person, in either mode

    func testInviteWithASyntheticEventSendsNothingAndIsReportedInEitherMode() throws {
        for staging in [false, true] {
            for makeSynthetic in [{ (rig: Rig) in rig.synthetic() }, { (rig: Rig) in rig.stamped() }] {
                let rig = offeredForm()
                if staging { try choose(stagingId, in: rig) }
                makeSynthetic(rig)
                try invite(in: rig)
                XCTAssertTrue(inviteFrames(rig).isEmpty, "staging only: \(staging)")
                XCTAssertEqual(refusals(rig).count, 1, "staging only: \(staging)")
                XCTAssertEqual(rig.recorder.messages.count, 1, "nothing else is sent")
                XCTAssertEqual(rig.recorder.closeCount, 0, "the popover stays up")
                XCTAssertEqual(try button(stagingId, in: rig).state, staging ? .on : .off, "the choice is kept")
            }
        }
    }

    func testInviteWithoutTheChoiceOfferedIsRefusedForASyntheticEventToo() throws {
        let rig = makeRig(offersStagingOnly: false)
        rig.synthetic()
        try invite(in: rig)
        XCTAssertEqual(rig.recorder.messages, [.refusalReport(terminalId: "t1", op: .followInvite, channel: "app_control")])
    }

    // MARK: (d) Changing what a follower gets

    func testAFullFollowerCanBeChangedToStagingOnlyFromTheMovePopover() throws {
        let rig = makeRig(follower: TerminalFollower(tag: "claudia-1", paused: false, pauseReason: nil), ownerTag: "core-1")
        try openMove(rig)

        // Output chosen: today's behaviour. Claudia already has it, so she is not listed.
        XCTAssertEqual(try button(outputId, in: rig).state, .on)
        XCTAssertEqual(try picker(in: rig).itemTitles, ["Core", "Cody"])
        XCTAssertEqual(try text("terminal-follow-heading", in: rig), "Move this terminal to another agent")

        // Staging only chosen: Claudia may be changed to it.
        try choose(stagingId, in: rig)
        XCTAssertEqual(try picker(in: rig).itemTitles, ["Core", "Claudia", "Cody"])
        try pick("Claudia", in: rig)
        XCTAssertEqual(try text("terminal-follow-heading", in: rig), "Change what Claudia gets")
        XCTAssertEqual(try text("terminal-follow-warning", in: rig),
                       "Claudia can stage commands for this terminal. Its output will NOT be sent to Claudia's model.")

        rig.person()
        try invite(in: rig)
        XCTAssertEqual(rig.recorder.messages, [.followInviteStagingOnly(terminalId: "t1", followerTag: "claudia-1")])
    }

    func testPickingAnotherAgentWhileChangingTheModeGoesBackToTheMoveHeading() throws {
        let rig = makeRig(follower: TerminalFollower(tag: "claudia-1", paused: false, pauseReason: nil), ownerTag: "core-1")
        try openMove(rig)
        try choose(stagingId, in: rig)
        try pick("Claudia", in: rig)
        try pick("Cody", in: rig)
        XCTAssertEqual(try text("terminal-follow-heading", in: rig), "Move this terminal to another agent")
    }

    func testChoosingOutputAgainDropsAFullFollowerFromThePickerAndTheChangeHeading() throws {
        let rig = makeRig(follower: TerminalFollower(tag: "claudia-1", paused: false, pauseReason: nil), ownerTag: "core-1")
        try openMove(rig)
        try choose(stagingId, in: rig)
        try pick("Claudia", in: rig)
        try choose(outputId, in: rig)
        XCTAssertEqual(try picker(in: rig).itemTitles, ["Core", "Cody"])
        XCTAssertNotEqual(try pickedTag(in: rig), "claudia-1")
        XCTAssertEqual(try text("terminal-follow-heading", in: rig), "Move this terminal to another agent")
    }

    private var stagingOnlyClaudia: TerminalFollower {
        TerminalFollower(tag: "claudia-1", paused: false, pauseReason: nil, mode: "staging_only")
    }

    func testAStagingOnlyFollowerCanBeChangedToOutputFromTheMovePopover() throws {
        let rig = makeRig(follower: stagingOnlyClaudia, ownerTag: "core-1")
        try openMove(rig)

        // Move opens on what she has now. Output is a change a person makes with a click, never the default.
        XCTAssertEqual(try button(stagingId, in: rig).state, .on)
        XCTAssertEqual(try button(outputId, in: rig).state, .off)
        XCTAssertEqual(try picker(in: rig).itemTitles, ["Core", "Cody"])
        try choose(outputId, in: rig)

        XCTAssertEqual(try button(outputId, in: rig).state, .on)
        XCTAssertEqual(try picker(in: rig).itemTitles, ["Core", "Claudia", "Cody"], "she gets no output yet, so Output is a change")
        try pick("Claudia", in: rig)
        XCTAssertEqual(try text("terminal-follow-heading", in: rig), "Change what Claudia gets")
        XCTAssertEqual(try text("terminal-follow-warning", in: rig), "Output will be sent to Claudia's model.")
        XCTAssertTrue(rig.recorder.messages.isEmpty, "nothing is sent until Invite")

        rig.person()
        try invite(in: rig)
        XCTAssertEqual(rig.recorder.messages, [.followInvite(terminalId: "t1", followerTag: "claudia-1", includeScreen: false)])
    }

    func testMoveOnAStagingOnlyFollowedPaneOpensOnStagingOnlyAndNeverSendsAFullInvite() throws {
        let rig = makeRig(follower: stagingOnlyClaudia, ownerTag: "core-1")
        try openMove(rig)

        XCTAssertEqual(try button(stagingId, in: rig).state, .on, "the Staging-only radio is on")
        XCTAssertEqual(try button(outputId, in: rig).state, .off, "the Output radio is off")
        XCTAssertEqual(try picker(in: rig).itemTitles, ["Core", "Cody"], "the other focuses, not the follower")
        XCTAssertEqual(try text("terminal-follow-heading", in: rig), "Move this terminal to another agent")
        XCTAssertEqual(try text("terminal-follow-warning", in: rig), rig.model.warning(forFocusTag: "core-1", mode: .stagingOnly))
        XCTAssertFalse(try button("terminal-follow-include-screen", in: rig).isEnabled, "there is no output to include")
        XCTAssertEqual(try button("terminal-follow-invite", in: rig).accessibilityLabel(), rig.model.inviteAccessibilityLabel(mode: .stagingOnly))

        try pick("Cody", in: rig)
        rig.person()
        try invite(in: rig)
        XCTAssertEqual(rig.recorder.messages, [.followInviteStagingOnly(terminalId: "t1", followerTag: "cody-1")])
        XCTAssertFalse(rig.recorder.messages.contains { if case .followInvite = $0 { return true } else { return false } },
                       "moving a staging-only follow must not start a full follow")
        XCTAssertEqual(rig.recorder.closeCount, 1)
    }

    func testMovingAStagingOnlyFollowToOutputNeedsAPersonsClickOnTheOutputRadio() throws {
        for makeSynthetic in [{ (rig: Rig) in rig.synthetic() }, { (rig: Rig) in rig.stamped() }] {
            let rig = makeRig(follower: stagingOnlyClaudia, ownerTag: "core-1")
            try openMove(rig)
            makeSynthetic(rig)
            try button(outputId, in: rig).performClick(nil)

            XCTAssertEqual(try button(stagingId, in: rig).state, .on, "a synthetic click does not escalate to Output")
            XCTAssertEqual(try button(outputId, in: rig).state, .off)
            XCTAssertEqual(try picker(in: rig).itemTitles, ["Core", "Cody"])
            XCTAssertEqual(rig.recorder.messages, [.refusalReport(terminalId: "t1", op: .followInvite, channel: "app_control")])

            rig.person()
            try invite(in: rig)
            XCTAssertEqual(inviteFrames(rig), [.followInviteStagingOnly(terminalId: "t1", followerTag: "core-1")],
                           "Invite after the refused click is still staging only")
        }
    }

    func testMoveWithTheStagingOnlyFollowerAsTheOnlyFocusOffersNoOneAndDisablesInvite() throws {
        let rig = makeRig(follower: stagingOnlyClaudia, ownerTag: "claudia-1", focuses: [claudia])
        try openMove(rig)

        XCTAssertEqual(try button(stagingId, in: rig).state, .on)
        XCTAssertEqual(try button(outputId, in: rig).state, .off)
        XCTAssertEqual(try picker(in: rig).itemTitles, [], "the follower is not offered staging only again")
        XCTAssertFalse(try button("terminal-follow-invite", in: rig).isEnabled, "nothing escalates silently")
        rig.person()
        try invite(in: rig)
        XCTAssertTrue(rig.recorder.messages.isEmpty, "Invite sends nothing, and certainly no full invite")
        XCTAssertEqual(rig.recorder.closeCount, 0)

        // Output is still a person's explicit choice, and then it is a visible change of what Claudia gets.
        try choose(outputId, in: rig)
        XCTAssertEqual(try picker(in: rig).itemTitles, ["Claudia"])
        XCTAssertEqual(try text("terminal-follow-heading", in: rig), "Change what Claudia gets")
        XCTAssertTrue(try button("terminal-follow-invite", in: rig).isEnabled)
        try invite(in: rig)
        XCTAssertEqual(rig.recorder.messages, [.followInvite(terminalId: "t1", followerTag: "claudia-1", includeScreen: false)])
    }

    func testMoveOnAFullFollowedPaneStillOpensOnOutput() throws {
        let rig = makeRig(follower: TerminalFollower(tag: "claudia-1", paused: false, pauseReason: nil), ownerTag: "core-1")
        try openMove(rig)
        XCTAssertEqual(try button(outputId, in: rig).state, .on)
        XCTAssertEqual(try button(stagingId, in: rig).state, .off)
        XCTAssertEqual(try picker(in: rig).itemTitles, ["Core", "Cody"])
        XCTAssertEqual(try text("terminal-follow-warning", in: rig), "Output will be sent to Core's model.")
    }

    func testTheManagePopoverOfAStagingOnlyFollowerSaysSoAndOffersStopAndMove() throws {
        let rig = makeRig(follower: TerminalFollower(tag: "claudia-1", paused: false, pauseReason: nil, mode: "staging_only"),
                          ownerTag: "core-1")
        XCTAssertEqual(try text("terminal-follow-status", in: rig), "Staging only: Claudia")
        XCTAssertEqual(try text("terminal-follow-detail", in: rig),
                       "Claudia can stage commands for you to place. This terminal's output is not sent to Claudia's model.")
        XCTAssertNotNil(find("terminal-follow-stop", in: rig))
        XCTAssertNotNil(find("terminal-follow-move", in: rig))
        XCTAssertNil(find("terminal-follow-resume", in: rig))
    }

    // MARK: (f) Nothing answers to a key

    func testNoButtonInTheFollowPopoverHasAKeyEquivalent() throws {
        let rigs = [
            makeRig(),
            makeRig(offersStagingOnly: false),
            makeRig(follower: TerminalFollower(tag: "claudia-1", paused: false, pauseReason: nil), ownerTag: "core-1"),
            makeRig(follower: TerminalFollower(tag: "claudia-1", paused: false, pauseReason: nil, mode: "staging_only"), ownerTag: "core-1"),
        ]
        for rig in rigs {
            let buttons = allViews(rig.view).compactMap { $0 as? NSButton }
            XCTAssertFalse(buttons.isEmpty)
            for b in buttons {
                XCTAssertEqual(b.keyEquivalent, "", "\(b.accessibilityIdentifier()) answers to a key")
            }
        }
        // Also with the staging-only choice made, where the radios and Invite are all showing.
        let rig = makeRig()
        try choose(stagingId, in: rig)
        for b in allViews(rig.view).compactMap({ $0 as? NSButton }) {
            XCTAssertEqual(b.keyEquivalent, "", "\(b.accessibilityIdentifier()) answers to a key")
        }
        let ids = Set(allViews(rig.view).map { $0.accessibilityIdentifier() })
        XCTAssertTrue(ids.contains(outputId) && ids.contains(stagingId))
    }
}
