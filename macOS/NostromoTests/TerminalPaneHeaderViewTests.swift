import XCTest
import AppKit

// `TerminalPaneHeaderView`: the band at the top of a terminal pane. A pane that is not known to be local
// is unmistakable at ANY size: the environment token ("PRODUCTION", or "REMOTE" when the daemon sent no
// target) is its own label on the left, always whole (never truncated, its font shrinks first), in a red
// header. Only the rest of the text truncates, and the mirror hint gives way before the title does.
// The view does not size itself: these tests give it a frame, as the host does, and lay it out.

final class TerminalPaneHeaderViewTests: XCTestCase {

    private let hint = "Mirroring at 132\u{00D7}43, type here to drive"
    private let longTarget = TerminalTarget(project: "an-extremely-long-project-name-that-cannot-fit",
                                            environment: "production",
                                            service: "an-equally-long-service-name-for-the-scheduler", shellType: "shell")
    private let shortTarget = TerminalTarget(project: "admin-portal", environment: "production", service: "scheduler", shellType: "shell")

    private func info(kind: TerminalKind, target: TerminalTarget?, label: String = "production") -> TerminalInfo {
        TerminalInfo(terminalId: "t1", tag: "core-1", paneId: "terminal-a", kind: kind, label: label, cwd: nil, target: target,
                     status: .running, exitCode: nil, endedReason: nil, cols: 80, rows: 24,
                     requestedBy: TerminalRequester(kind: "user", tag: nil), openedByRequest: nil, follower: nil, idleClosesAt: nil)
    }

    private func makeHeader(_ info: TerminalInfo?, width: CGFloat, height: CGFloat = TerminalPaneHeaderView.height,
                            mirrorHint: String = "") -> TerminalPaneHeaderView {
        let header = TerminalPaneHeaderView()
        header.frame = NSRect(x: 0, y: 0, width: width, height: height)
        header.apply(info: info, mirrorHint: mirrorHint)
        header.layoutSubtreeIfNeeded()
        return header
    }

    private func label(_ id: String, in header: TerminalPaneHeaderView, file: StaticString = #filePath, line: UInt = #line) throws -> NSTextField {
        try XCTUnwrap(descendants(header).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == id },
                      "no label \(id)", file: file, line: line)
    }

    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    private func overlaps(_ a: NSRect, _ b: NSRect) -> Bool {
        let i = a.intersection(b)
        return !i.isNull && i.width > 0.5 && i.height > 0.5
    }

    private func sameColor(_ cgColor: CGColor?, _ color: NSColor, file: StaticString = #filePath, line: UInt = #line) {
        guard let cgColor, let a = NSColor(cgColor: cgColor)?.usingColorSpace(.sRGB), let b = color.usingColorSpace(.sRGB)
        else { return XCTFail("no colour", file: file, line: line) }
        XCTAssertEqual(a.redComponent, b.redComponent, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(a.greenComponent, b.greenComponent, accuracy: 0.01, file: file, line: line)
        XCTAssertEqual(a.blueComponent, b.blueComponent, accuracy: 0.01, file: file, line: line)
    }

    // MARK: The token at narrow widths

    func testTheEnvironmentTokenIsShownInFullAtEveryWidthNextToALongTitleAndAHint() throws {
        for width in [120.0, 160, 240, 400, 700] {
            let header = makeHeader(info(kind: .ecs, target: longTarget), width: width, mirrorHint: hint)
            let env = try label("terminal-environment", in: header)
            let title = try label("terminal-title", in: header)
            let mirror = try label("terminal-mirror-hint", in: header)
            let close = try XCTUnwrap(descendants(header).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "terminal-close-x" })
            let context = "width \(Int(width))"

            XCTAssertFalse(env.isHidden, context)
            XCTAssertEqual(env.stringValue, "PRODUCTION", "never truncated or abbreviated: \(context)")
            XCTAssertEqual(env.lineBreakMode, .byClipping, context)
            XCTAssertEqual(env.frame.width, env.intrinsicContentSize.width, accuracy: 1, "fixed at its intrinsic width: \(context)")
            XCTAssertEqual(env.frame.minX, 10, accuracy: 0.5, "left-aligned at x=10: \(context)")
            XCTAssertTrue(header.bounds.insetBy(dx: -0.5, dy: -0.5).contains(env.frame), "inside the header: \(context)")

            var others: [(String, NSRect)] = [("title", title.frame), ("close button", close.frame)]
            if !mirror.isHidden { others.append(("hint", mirror.frame)) }
            for (name, other) in others where other.width > 0.5 {
                XCTAssertFalse(overlaps(env.frame, other), "the token overlaps the \(name): \(context)")
                XCTAssertLessThanOrEqual(env.frame.maxX, other.minX + 0.5, "the token is left of the \(name): \(context)")
            }
            if !mirror.isHidden { XCTAssertFalse(overlaps(title.frame, mirror.frame), "title and hint overlap: \(context)") }
            XCTAssertEqual(title.stringValue, "\(longTarget.project) \u{00B7} \(longTarget.service) \u{00B7} shell",
                           "the title holds only the rest: \(context)")
        }
    }

    func testTheHintGivesWayBeforeTheTitleDoes() throws {
        for width in stride(from: 100.0, through: 700, by: 20) {
            let header = makeHeader(info(kind: .ecs, target: shortTarget), width: width, mirrorHint: hint)
            let title = try label("terminal-title", in: header)
            let mirror = try label("terminal-mirror-hint", in: header)
            if title.frame.width < title.intrinsicContentSize.width - 1 {
                XCTAssertTrue(mirror.isHidden || mirror.frame.width < 1,
                              "width \(Int(width)): the title is truncated while the hint still takes \(mirror.frame.width) pt")
            }
        }
    }

    func testAWideRemoteHeaderShowsTheTokenTheWholeTitleAndTheHintWithoutOverlap() throws {
        let header = makeHeader(info(kind: .ecs, target: shortTarget), width: 900, mirrorHint: hint)
        let env = try label("terminal-environment", in: header)
        let title = try label("terminal-title", in: header)
        let mirror = try label("terminal-mirror-hint", in: header)
        XCTAssertEqual(title.stringValue, "admin-portal \u{00B7} scheduler \u{00B7} shell")
        XCTAssertFalse(mirror.isHidden)
        XCTAssertGreaterThan(mirror.frame.width, 1)
        XCTAssertGreaterThanOrEqual(title.frame.width, title.intrinsicContentSize.width - 1, "the title is not cut when there is room")
        XCTAssertFalse(overlaps(env.frame, title.frame))
        XCTAssertFalse(overlaps(title.frame, mirror.frame))
        XCTAssertFalse(overlaps(env.frame, mirror.frame))
    }

    // MARK: Short panes

    func testTheRedHeaderKeepsTheTokenInsideItAtEveryHeight() throws {
        XCTAssertEqual(TerminalPaneHeaderView.height, 24)
        for height in [24.0, 18, 12] {
            let header = makeHeader(info(kind: .ecs, target: shortTarget), width: 300, height: height)
            let env = try label("terminal-environment", in: header)
            let context = "height \(Int(height))"
            sameColor(header.layer?.backgroundColor, Theme.hazardRed)
            XCTAssertFalse(env.isHidden, context)
            XCTAssertGreaterThan(env.frame.height, 0, context)
            XCTAssertTrue(header.bounds.insetBy(dx: -0.5, dy: -0.5).contains(env.frame),
                          "the token is clipped by the header: \(context), token \(env.frame) in header \(header.bounds)")
            XCTAssertEqual(env.stringValue, "PRODUCTION", context)
        }
    }

    func testTheTokenStaysInsideTheHeaderWhenBothWidthAndHeightAreSmall() throws {
        for (width, height) in [(120.0, 12.0), (120, 18), (100, 24)] {
            let header = makeHeader(info(kind: .ecs, target: longTarget), width: width, height: height, mirrorHint: hint)
            let env = try label("terminal-environment", in: header)
            XCTAssertTrue(header.bounds.insetBy(dx: -0.5, dy: -0.5).contains(env.frame), "\(Int(width))x\(Int(height)): \(env.frame) in \(header.bounds)")
            XCTAssertEqual(env.stringValue, "PRODUCTION")
        }
    }

    // MARK: Kinds

    func testAnUnknownKindPaneWithNoTargetIsRedAndSaysRemote() throws {
        let header = makeHeader(info(kind: .unknown, target: nil, label: "mystery"), width: 400)
        sameColor(header.layer?.backgroundColor, Theme.hazardRed)
        let env = try label("terminal-environment", in: header)
        XCTAssertFalse(env.isHidden)
        XCTAssertEqual(env.stringValue, "REMOTE")
        XCTAssertEqual(try label("terminal-title", in: header).stringValue, "mystery")
    }

    func testAnEcsPaneWithNoTargetIsRedAndSaysRemote() throws {
        let header = makeHeader(info(kind: .ecs, target: nil, label: "some shell"), width: 400)
        sameColor(header.layer?.backgroundColor, Theme.hazardRed)
        XCTAssertEqual(try label("terminal-environment", in: header).stringValue, "REMOTE")
        XCTAssertEqual(try label("terminal-title", in: header).stringValue, "some shell")
    }

    func testAnEcsPaneWithATargetShowsTheEnvironmentAndTheRestInTheTitle() throws {
        let canada = TerminalTarget(project: "admin-portal", environment: "canada", service: "scheduler", shellType: "shell")
        let header = makeHeader(info(kind: .ecs, target: canada, label: "canada"), width: 500)
        XCTAssertEqual(try label("terminal-environment", in: header).stringValue, "CANADA")
        XCTAssertEqual(try label("terminal-title", in: header).stringValue, "admin-portal \u{00B7} scheduler \u{00B7} shell")
        sameColor(header.layer?.backgroundColor, Theme.hazardRed)
    }

    func testALocalPaneHasNoTokenAndAPlainHeader() throws {
        let header = makeHeader(info(kind: .local, target: nil, label: "zsh"), width: 400)
        XCTAssertTrue(try label("terminal-environment", in: header).isHidden)
        sameColor(header.layer?.backgroundColor, Theme.bgBar)
    }

    func testAPaneNotYetDescribedIsAPlainTerminalHeader() throws {
        let header = makeHeader(nil, width: 400)
        XCTAssertTrue(try label("terminal-environment", in: header).isHidden)
        XCTAssertEqual(try label("terminal-title", in: header).stringValue, "Terminal")
        sameColor(header.layer?.backgroundColor, Theme.bgBar)
    }

    func testTheHeaderBecomesRedWhenALocalPaneIsReplacedByARemoteOne() throws {
        let header = makeHeader(info(kind: .local, target: nil, label: "zsh"), width: 400)
        header.apply(info: info(kind: .ecs, target: shortTarget), mirrorHint: "")
        header.layoutSubtreeIfNeeded()
        sameColor(header.layer?.backgroundColor, Theme.hazardRed)
        XCTAssertFalse(try label("terminal-environment", in: header).isHidden)
        header.apply(info: info(kind: .local, target: nil, label: "zsh"), mirrorHint: "")
        XCTAssertTrue(try label("terminal-environment", in: header).isHidden)
        sameColor(header.layer?.backgroundColor, Theme.bgBar)
    }

    func testTheMirrorHintIsHiddenWithoutHintText() throws {
        let header = makeHeader(info(kind: .ecs, target: shortTarget), width: 600, mirrorHint: "")
        XCTAssertTrue(try label("terminal-mirror-hint", in: header).isHidden)
    }

    // MARK: The Follow badge

    private let claudia = FollowFocusOption(tag: "claudia-1", name: "Claudia")

    private func followInfo(kind: TerminalKind = .local, target: TerminalTarget? = nil,
                            follower: TerminalFollower? = nil) -> TerminalInfo {
        TerminalInfo(terminalId: "t1", tag: "core-1", paneId: "terminal-a", kind: kind, label: "zsh", cwd: nil, target: target,
                     status: .running, exitCode: nil, endedReason: nil, cols: 80, rows: 24,
                     requestedBy: TerminalRequester(kind: "user", tag: nil), openedByRequest: nil, follower: follower, idleClosesAt: nil)
    }

    private func followModel(_ info: TerminalInfo) -> FollowModel {
        FollowModel(info: info, focuses: [claudia])
    }

    private func makeFollowHeader(_ info: TerminalInfo, width: CGFloat, mirrorHint: String = "") -> TerminalPaneHeaderView {
        let header = TerminalPaneHeaderView()
        header.frame = NSRect(x: 0, y: 0, width: width, height: TerminalPaneHeaderView.height)
        header.apply(info: info, mirrorHint: mirrorHint, follow: followModel(info))
        header.layoutSubtreeIfNeeded()
        return header
    }

    private var followedByClaudia: TerminalFollower { TerminalFollower(tag: "claudia-1", paused: false, pauseReason: nil) }
    private var pausedClaudia: TerminalFollower { TerminalFollower(tag: "claudia-1", paused: true, pauseReason: "too_much_output") }

    func testTheBadgeIsAlwaysVisibleInsideTheHeaderAndClearOfEverythingElseAtEveryWidth() throws {
        let infos = [followInfo(), followInfo(kind: .ecs, target: longTarget), followInfo(follower: followedByClaudia),
                     followInfo(kind: .ecs, target: longTarget, follower: pausedClaudia)]
        for info in infos {
            for width in [100.0, 110, 120, 160, 240, 400, 700] {
                let header = makeFollowHeader(info, width: width, mirrorHint: hint)
                let badge = header.followButton
                let context = "\(info.kind) follower \(info.follower != nil) width \(Int(width))"
                XCTAssertFalse(badge.isHidden, context)
                XCTAssertGreaterThanOrEqual(badge.frame.width, 20, "the badge never vanishes: \(context)")
                XCTAssertGreaterThan(badge.frame.height, 0, context)
                XCTAssertTrue(header.bounds.insetBy(dx: -0.5, dy: -0.5).contains(badge.frame), "inside the header: \(context)")

                let close = try XCTUnwrap(descendants(header).compactMap { $0 as? NSButton }.first { $0.accessibilityIdentifier() == "terminal-close-x" })
                var others: [(String, NSRect)] = [("close button", close.frame)]
                let title = try label("terminal-title", in: header)
                let mirror = try label("terminal-mirror-hint", in: header)
                if title.frame.width > 0.5 { others.append(("title", title.frame)) }
                if !mirror.isHidden, mirror.frame.width > 0.5 { others.append(("hint", mirror.frame)) }
                // Below ~120 pt a remote header cannot hold even the smallest token next to a 20 pt badge.
                if info.kind == .local || width >= 120 {
                    let env = try label("terminal-environment", in: header)
                    if !env.isHidden { others.append(("environment token", env.frame)) }
                }
                for (name, other) in others {
                    XCTAssertFalse(overlaps(badge.frame, other), "the badge overlaps the \(name): \(context)")
                }
            }
        }
    }

    func testTheBadgeHasItsMinimumWidthWhereThereIsRoom() {
        for info in [followInfo(), followInfo(follower: followedByClaudia), followInfo(follower: pausedClaudia)] {
            for width in [300.0, 400, 700] {
                let header = makeFollowHeader(info, width: width, mirrorHint: hint)
                XCTAssertGreaterThanOrEqual(header.followButton.frame.width, FollowModel.badgeMinWidth - 0.5, "local width \(Int(width))")
            }
        }
        for info in [followInfo(kind: .ecs, target: shortTarget), followInfo(kind: .ecs, target: shortTarget, follower: followedByClaudia)] {
            for width in [300.0, 400, 700] {
                let header = makeFollowHeader(info, width: width, mirrorHint: hint)
                XCTAssertGreaterThanOrEqual(header.followButton.frame.width, FollowModel.badgeMinWidth - 0.5, "remote width \(Int(width))")
            }
        }
    }

    func testARemoteHeaderWithABadgeStillShowsTheTokenWholeLeftAlignedAndClearOfTheBadge() throws {
        for follower in [nil, followedByClaudia, pausedClaudia] as [TerminalFollower?] {
            for width in [300.0, 400, 700] {
                let header = makeFollowHeader(followInfo(kind: .ecs, target: longTarget, follower: follower), width: width, mirrorHint: hint)
                let env = try label("terminal-environment", in: header)
                let context = "follower \(follower != nil) width \(Int(width))"
                XCTAssertFalse(env.isHidden, context)
                XCTAssertEqual(env.stringValue, "PRODUCTION", context)
                XCTAssertEqual(env.lineBreakMode, .byClipping, context)
                XCTAssertEqual(env.frame.width, env.intrinsicContentSize.width, accuracy: 1, "not cut: \(context)")
                XCTAssertEqual(env.frame.minX, 10, accuracy: 0.5, context)
                XCTAssertFalse(overlaps(env.frame, header.followButton.frame), "token and badge overlap: \(context)")
                XCTAssertLessThanOrEqual(env.frame.maxX, header.followButton.frame.minX + 0.5, context)
            }
        }
    }

    func testTheTokenKeepsItsFullSizeBesideAShortBadgeWhereThereIsRoom() throws {
        // The badge gives up room (down to its minimum) before the token's font shrinks.
        let header = makeFollowHeader(followInfo(kind: .ecs, target: shortTarget), width: 300)
        let env = try label("terminal-environment", in: header)
        XCTAssertEqual(env.font?.pointSize ?? 0, 12, accuracy: 0.01)
    }

    func testTheBadgeShowsWhatTheFollowModelSays() {
        let cases: [(TerminalFollower?, String)] = [(nil, "Not shared"), (followedByClaudia, "Followed by Claudia"),
                                                    (pausedClaudia, "Paused, too much output")]
        for kind in [TerminalKind.local, .ecs] {
            for (follower, text) in cases {
                let info = followInfo(kind: kind, target: kind == .ecs ? shortTarget : nil, follower: follower)
                let header = makeFollowHeader(info, width: 500)
                XCTAssertEqual(header.followButton.attributedTitle.string, text, "\(kind)")
            }
        }
    }

    func testTheBadgeSaysNotSharedWhenThePaneIsNotDescribedYet() {
        let header = makeHeader(nil, width: 400)
        XCTAssertFalse(header.followButton.isHidden)
        XCTAssertEqual(header.followButton.attributedTitle.string, "Not shared")
    }

    func testTheBadgeIsFilledWithTheModelsColourNeverTheHeadersRed() throws {
        for kind in [TerminalKind.local, .ecs] {
            for follower in [nil, followedByClaudia, pausedClaudia] as [TerminalFollower?] {
                let info = followInfo(kind: kind, target: kind == .ecs ? shortTarget : nil, follower: follower)
                let header = makeFollowHeader(info, width: 500)
                let fill = header.followButton.layer?.backgroundColor
                sameColor(fill, followModel(info).badgeColor)
                let a = try XCTUnwrap(fill.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) })
                let red = Theme.hazardRed.usingColorSpace(.sRGB)!
                let distance = abs(a.redComponent - red.redComponent) + abs(a.greenComponent - red.greenComponent)
                    + abs(a.blueComponent - red.blueComponent)
                XCTAssertGreaterThan(distance, 0.3, "the badge must not look like the red header: \(kind)")
            }
        }
    }

    func testTheBadgeColourFollowsTheState() {
        let info = followInfo()
        let header = makeFollowHeader(info, width: 500)
        sameColor(header.followButton.layer?.backgroundColor, Theme.fgMuted)
        let followed = followInfo(follower: followedByClaudia)
        header.apply(info: followed, mirrorHint: "", follow: followModel(followed))
        sameColor(header.followButton.layer?.backgroundColor, Theme.followBlue)
        XCTAssertEqual(header.followButton.attributedTitle.string, "Followed by Claudia")
        let paused = followInfo(follower: pausedClaudia)
        header.apply(info: paused, mirrorHint: "", follow: followModel(paused))
        sameColor(header.followButton.layer?.backgroundColor, Theme.amber)
    }

    func testTheTooltipAndAccessibilityLabelCarryTheWholeSentenceEvenWhenTheBadgeIsSqueezed() {
        for width in [100.0, 500] {
            for follower in [nil, followedByClaudia, pausedClaudia] as [TerminalFollower?] {
                let info = followInfo(kind: .ecs, target: longTarget, follower: follower)
                let model = followModel(info)
                let header = makeFollowHeader(info, width: width)
                XCTAssertEqual(header.followButton.toolTip, model.badgeDescription, "width \(Int(width))")
                let spoken = header.followButton.accessibilityLabel() ?? ""
                XCTAssertTrue(spoken.contains(model.badgeText), spoken)
                XCTAssertTrue(spoken.contains(model.badgeDescription), spoken)
            }
        }
    }

    func testTheBadgeHasItsAccessibilityIdentifier() {
        XCTAssertEqual(TerminalPaneHeaderView().followButton.accessibilityIdentifier(), "terminal-follow")
    }
}


// MARK: - S2: the `3 staged` chip

extension TerminalPaneHeaderViewTests {

    func testTheChipNeverDisplacesOrClipsTheEnvironmentTokenAtAnyWidth() throws {
        let pane = info(kind: .ecs, target: longTarget)
        for width in [CGFloat(120), 200, 280, 400, 700] {
            let plain = makeHeader(pane, width: width)
            let withChip = makeHeader(pane, width: width)
            withChip.setStagedChip(count: 3)
            withChip.layoutSubtreeIfNeeded()
            let token = try label("terminal-environment", in: withChip)
            let reference = try label("terminal-environment", in: plain)
            XCTAssertEqual(token.frame, reference.frame, "\(width) pt: the token is where it was, whole")
            if withChip.isChipShown {
                XCTAssertFalse(overlaps(withChip.stagedChip.frame, token.frame), "\(width) pt: the chip sits after the token")
                XCTAssertGreaterThanOrEqual(withChip.stagedChip.frame.minX, token.frame.maxX, "\(width)")
                XCTAssertLessThanOrEqual(withChip.stagedChip.frame.maxX, withChip.followButton.frame.minX + 0.5, "\(width)")
            }
        }
        XCTAssertFalse(makeHeaderWithChip(width: 120).isChipShown, "no room at 120 pt: the chip hides before the token would clip")
        XCTAssertTrue(makeHeaderWithChip(width: 700).isChipShown)
    }

    private func makeHeaderWithChip(width: CGFloat) -> TerminalPaneHeaderView {
        let header = makeHeader(info(kind: .ecs, target: shortTarget), width: width)
        header.setStagedChip(count: 3)
        header.layoutSubtreeIfNeeded()
        return header
    }

    func testTheChipSaysHowManyAndHidesWhenTheCountIsNil() {
        let header = makeHeaderWithChip(width: 700)
        XCTAssertEqual(header.stagedChip.attributedTitle.string, "3 staged")
        XCTAssertFalse(header.stagedChip.isHidden)
        header.setStagedChip(count: nil)
        header.layoutSubtreeIfNeeded()
        XCTAssertTrue(header.stagedChip.isHidden)
    }

    func testALocalHeaderShowsTheChipBeforeTheTitleAndPulsesOnANewEntry() {
        let header = makeHeader(info(kind: .local, target: nil, label: "zsh"), width: 400)
        header.setStagedChip(count: 2)
        header.layoutSubtreeIfNeeded()
        XCTAssertTrue(header.isChipShown)
        XCTAssertEqual(header.chipPulseCount, 0)
        header.setStagedChip(count: 3, pulse: true)
        XCTAssertEqual(header.chipPulseCount, 1)
    }
}
