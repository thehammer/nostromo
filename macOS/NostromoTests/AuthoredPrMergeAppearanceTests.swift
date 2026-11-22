import XCTest
import AppKit
import NostromoKit

// What the Perri badge and the Merge button put on a PR row, measured from real renders (never from frames
// alone: a frame check cannot see a clipped last letter, and shipped one three times before). The worst row there
// is (a 200-character title, ten reviewers, a 4-digit comment count, an `owner/name` chip, a long owner line), at
// 320 and 380 pt (the Mother pane's narrow widths) in dark and light appearance over the palette background, in
// every state a merge can be in:
//   ready, Perri's approval is for an older version, Perri asked for changes, Perri only commented, Perri has not
//   reviewed, Merging…, Merged, and a failure notice.
//
// "Ink" is a pixel that differs from the background. Whole-ness is judged against the ink of the same text drawn
// alone and unclipped (`APT.referenceInk`).
//
// MEASURING A BUTTON'S TITLE. A button's bezel is ink too, so a button's title is painted pure red (same string,
// same font, so the same layout) and measured by its colour (`APT.redInk`). `Merging…` and `Merged` are disabled
// buttons; a disabled button's title is drawn dimmed. Whether a title is whole does not depend on whether the
// button is on, so for the measurement the button is turned on first (and its size checked not to change).
//
// NAMED MUTATION TESTS. A measurement that cannot fail proves nothing, so one test feeds the same helper a
// deliberately broken input and demands that the check FAILS:
//   * testMutationASqueezedMergeButtonFailsTheTitleCheck: the same button squeezed to a narrow fixed width.
// Mutations of the source (to be run by hand), and the test that fails for each:
//   M1 the badge may be compressed (compression resistance lowered)
//        -> testThePerriBadgeIsDrawnWholeAndInsideTheRow
//   M2 the older approval is drawn as strongly as a current one
//        -> testAnOlderApprovalIsVisiblyDimmerThanACurrentOne
//   M3 a palette colour for the badge or the notice drops below 4.5:1
//        -> testEveryBadgeColourAndTheNoticeColourHasAtLeast4_5To1Contrast
//   M4 the button's width follows its title (Merge / Merging… / Merged)
//        -> testTheMergeButtonKeepsItsSizeAndPlaceInEveryState
//   M5 the title of the button is clipped, or the button is allowed to compress
//        -> testTheMergeButtonTitleIsDrawnWholeInEveryState
//   M6 a line runs under the button, or past the row's right edge
//        -> testNothingInksPastTheRowsEdgeOrIntoTheMergeButton
//   M7 the notice takes more height than the owner line (the row grows) or sits elsewhere
//        -> testTheNoticeTakesThePlaceOfTheOwnerLineAtTheSameHeight, testTheRowKeepsItsHeightInEveryState
//   M8 the notice is cut with no way to read it
//        -> testTheNoticeIsShownWholeOrCutWithItsFullTextInATooltip
//   M9 the title stops truncating at the tail, or loses its tooltip
//        -> testALongTitleStillEndsInAnEllipsisWithItsTooltip
//   M10 the row's accessibility label or custom actions lose the Merge / Dismiss merge message names
//        -> testVoiceOverGetsTheRowsWordsAndTheRightActionsInEveryState
final class AuthoredPrMergeAppearanceTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func tearDown() {
        for window in windows { window.contentView = nil; window.close() }
        windows = []
        super.tearDown()
    }

    private static let widths: [CGFloat] = [320, 380]
    private static let appearances: [(name: NSAppearance.Name, label: String)] = [(.darkAqua, "dark"), (.aqua, "light")]

    private static let title = String(repeating: "l", count: 200)

    // MARK: - The worst row, in every state

    private enum Scenario: String, CaseIterable {
        case ready, olderApproval, changesRequested, comments, noVerdict, merging, merged, notice
        // The merge queue: how the button reads for a PR that goes in through one.
        case queueReady, queueNeedsUpdate, adding, inQueue, inQueueAtPosition, dropped

        var hasBadge: Bool { self != .noVerdict }
        var buttonTitle: String {
            switch self {
            case .merging: return "Merging…"
            case .merged: return "Merged"
            case .queueReady, .queueNeedsUpdate, .dropped: return "Add to merge queue"
            case .adding: return "Adding…"
            case .inQueue: return "In merge queue"
            case .inQueueAtPosition: return "In merge queue (9999)"
            default: return "Merge"
            }
        }
        var hasNotice: Bool { self == .notice || self == .dropped }
        /// The button is on: the person may press it.
        var isReady: Bool { self == .ready || self == .notice || self == .queueReady || self == .dropped }
        /// The row says it goes in through the merge queue.
        var isQueue: Bool {
            switch self {
            case .queueReady, .queueNeedsUpdate, .adding, .inQueue, .inQueueAtPosition, .dropped: return true
            default: return false
            }
        }
    }

    private static func model(_ scenario: Scenario) -> AuthoredPrRowModel {
        let perri: AuthoredPrPerri?
        switch scenario {
        case .olderApproval: perri = MF.verdict(.approved, current: false)
        case .changesRequested: perri = MF.verdict(.changesRequested)
        case .comments: perri = MF.verdict(.comment)
        case .noVerdict: perri = nil
        default: perri = MF.verdict(.approved)
        }
        var pr = MF.readyPr(123, title: title, baseRef: "slash-commands-0",
                            checks: AuthoredPrChecks(state: .passing, passed: 9),
                            review: AuthoredPrReview(state: .approved, logins: (1...10).map { "reviewer-login-\($0)" }),
                            perri: perri, owner: APT.motherOwner())
        pr.newComments = 1234
        pr.unresolvedThreads = 12
        if scenario.isQueue { pr.mergeVia = .queue }
        if scenario == .inQueueAtPosition { pr.queue = AuthoredPrQueue(state: .queued, position: 9999) }
        var attempt: AuthoredPrMergeAttempt?
        switch scenario {
        case .adding: attempt = AuthoredPrMergeAttempt(head: MF.headA, progress: .merging)
        case .inQueue: attempt = AuthoredPrMergeAttempt(head: MF.headA, progress: .queued)
        case .dropped: attempt = AuthoredPrMergeAttempt(head: MF.headA, progress: .failed(.droppedFromQueue), sawQueueEntry: true)
        case .merging: attempt = AuthoredPrMergeAttempt(head: MF.headA, progress: .merging)
        case .merged: attempt = AuthoredPrMergeAttempt(head: MF.headA, progress: .merged)
        case .notice: attempt = AuthoredPrMergeAttempt(head: MF.headA, progress: .failed(.perriStale))
        default: attempt = nil
        }
        return AuthoredPrsPresentation.row(pr, chip: "owner/name", now: APT.t0, perri: true, merge: true,
                                           mergeQueue: scenario.isQueue && scenario != .queueNeedsUpdate,
                                           mergeAttempt: attempt)
    }

    private struct Rendered {
        let host: AuthoredPrsInkHost
        let row: AuthoredPrRowView
        let model: AuthoredPrRowModel
        let scenario: Scenario
        let bitmap: APT.Bitmap
        let width: CGFloat
        let appearance: NSAppearance.Name
        let context: String
        func rect(_ view: NSView) -> NSRect { APT.rect(of: view, in: host) }
    }

    /// `measuringTitles`: the Merge button is turned on and its title painted red, for `APT.redInk`.
    private func render(_ scenario: Scenario, width: CGFloat, appearance: (name: NSAppearance.Name, label: String),
                        measuringTitles: Bool = false, model override: AuthoredPrRowModel? = nil) -> Rendered? {
        let model = override ?? Self.model(scenario)
        let (host, window) = APT.inkHost(size: NSSize(width: width, height: 120), appearance: appearance.name)
        windows.append(window)
        let row = AuthoredPrRowView()
        row.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: host.topAnchor),
            row.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            row.widthAnchor.constraint(equalToConstant: width),
        ])
        row.configure(model)
        host.layoutSubtreeIfNeeded()
        let context = "'\(scenario.rawValue)' at \(Int(width)) pt, \(appearance.label)"
        if measuringTitles, !row.mergeButton.isHidden {
            let before = row.mergeButton.frame
            row.mergeButton.isEnabled = true
            APT.paintTitleRed(row.mergeButton)
            host.layoutSubtreeIfNeeded()
            let after = row.mergeButton.frame
            if abs(before.width - after.width) > 0.5 || abs(before.height - after.height) > 0.5 {
                XCTFail("\(context): measuring the title changed the button's size \(before.size) to \(after.size); the measurement is not valid")
                return nil
            }
        }
        guard let bitmap = APT.render(host) else { return nil }
        return Rendered(host: host, row: row, model: model, scenario: scenario, bitmap: bitmap, width: width,
                        appearance: appearance.name, context: context)
    }

    private func eachRendering(measuringTitles: Bool = false, _ body: (Rendered) throws -> Void) rethrows {
        for scenario in Scenario.allCases {
            for appearance in Self.appearances {
                for width in Self.widths {
                    guard let rendered = render(scenario, width: width, appearance: appearance, measuringTitles: measuringTitles) else { continue }
                    try body(rendered)
                }
            }
        }
    }

    /// `rect` grown a little each way so ink that a too-small frame would clip is still seen.
    private func grown(_ rect: NSRect) -> NSRect { rect.insetBy(dx: -1.5, dy: -2) }

    /// The strongest colour distance from the background of any pixel in `rect`: how loud the text is.
    private func peak(_ bitmap: APT.Bitmap, in rect: NSRect) -> CGFloat {
        let rep = bitmap.rep, scale = bitmap.scale
        let r = rect.intersection(NSRect(origin: .zero, size: bitmap.size))
        guard !r.isNull, r.width > 0, r.height > 0 else { return 0 }
        let x0 = max(0, Int((r.minX * scale).rounded(.down))), x1 = min(rep.pixelsWide, Int((r.maxX * scale).rounded(.up)))
        let y0 = max(0, Int((r.minY * scale).rounded(.down))), y1 = min(rep.pixelsHigh, Int((r.maxY * scale).rounded(.up)))
        guard x0 < x1, y0 < y1 else { return 0 }
        var best: CGFloat = 0
        for y in y0..<y1 {
            for x in x0..<x1 {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                let d = max(abs(c.redComponent - bitmap.background.r), abs(c.greenComponent - bitmap.background.g),
                            abs(c.blueComponent - bitmap.background.b))
                best = max(best, d)
            }
        }
        return best
    }

    /// The ink of `view`'s text must be at least as wide as the same text drawn whole.
    private func assertWhole(_ r: Rendered, _ view: NSTextField, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let ink = r.bitmap.ink(in: grown(r.rect(view))) else {
            return XCTFail("\(r.context): \(what) drew nothing", file: file, line: line)
        }
        let text = APT.attributed(view.stringValue, font: view.font ?? .systemFont(ofSize: 11), color: view.textColor ?? AuthoredPrsPalette.text)
        guard let reference = APT.referenceInk(text, appearance: r.appearance, scale: r.bitmap.scale) else {
            return XCTFail("could not draw the reference for \(what)", file: file, line: line)
        }
        XCTAssertGreaterThanOrEqual(ink.width, reference.width - r.bitmap.tolerance,
                                    "\(r.context): \(what) is clipped (ink \(ink.width) pt wide, whole is \(reference.width))", file: file, line: line)
    }

    // MARK: - The Perri badge

    func testThePerriBadgeIsDrawnWholeAndInsideTheRow() {
        eachRendering { r in
            guard r.scenario.hasBadge else {
                XCTAssertTrue(r.row.perriLabel.isHidden, "\(r.context): no verdict, no badge")
                return
            }
            XCTAssertFalse(r.row.perriLabel.isHidden, "\(r.context): precondition, the row has its badge")
            XCTAssertEqual(r.row.perriLabel.stringValue, r.model.perriBadge?.text, r.context)
            assertWhole(r, r.row.perriLabel, "the Perri badge '\(r.row.perriLabel.stringValue)'")
            let frame = r.rect(r.row.perriLabel)
            XCTAssertLessThanOrEqual(frame.maxX, r.width - AuthoredPrRowView.sidePadding + 0.5, "\(r.context): the badge is inside the row's padding")
            XCTAssertGreaterThanOrEqual(frame.minX, 0, "\(r.context)")
            XCTAssertLessThanOrEqual(frame.width, r.width, "\(r.context): never wider than the row")
            if let ink = r.bitmap.ink(in: grown(frame)) {
                XCTAssertLessThanOrEqual(ink.maxX, r.width - 2, "\(r.context): the badge's ink reaches the row's right edge")
            }
        }
    }

    func testTheBadgeDoesNotRunIntoOtherPartsOfTheRow() {
        eachRendering { r in
            guard r.scenario.hasBadge else { return }
            let badge = r.rect(r.row.perriLabel)
            var others: [(String, NSView)] = [("status", r.row.statusLabel), ("number", r.row.numberLabel), ("title", r.row.titleLabel),
                                              ("repo chip", r.row.repoChip), ("age", r.row.ageLabel)]
            if !r.row.mergeButton.isHidden { others.append(("Merge button", r.row.mergeButton)) }
            for (name, view) in others {
                XCTAssertFalse(badge.intersects(r.rect(view)), "\(r.context): the badge overlaps the \(name) (\(badge) and \(r.rect(view)))")
            }
        }
    }

    func testAnOlderApprovalIsVisiblyDimmerThanACurrentOne() {
        for appearance in Self.appearances {
            for width in Self.widths {
                guard let current = render(.ready, width: width, appearance: appearance),
                      let older = render(.olderApproval, width: width, appearance: appearance) else { continue }
                XCTAssertEqual(current.row.perriLabel.stringValue, "Perri ✓", "precondition")
                XCTAssertEqual(older.row.perriLabel.stringValue, "Perri ✓ older", "precondition")
                let loud = peak(current.bitmap, in: grown(current.rect(current.row.perriLabel)))
                let quiet = peak(older.bitmap, in: grown(older.rect(older.row.perriLabel)))
                XCTAssertGreaterThan(loud, 0.3, "\(current.context): precondition, the current badge is drawn")
                XCTAssertLessThan(quiet, loud - 0.03, "\(older.context): 'Perri ✓ older' (\(quiet)) is not dimmer than 'Perri ✓' (\(loud))")
            }
        }
    }

    func testTheBadgesToolTipAndSpokenLabelComeFromTheModel() {
        eachRendering { r in
            guard let badge = r.model.perriBadge else { return }
            XCTAssertEqual(r.row.perriLabel.toolTip, badge.tooltip, r.context)
            XCTAssertEqual(r.row.perriLabel.accessibilityLabel(), badge.accessibilityLabel, r.context)
            XCTAssertFalse(badge.tooltip.isEmpty, r.context)
        }
    }

    // MARK: - Contrast

    func testEveryBadgeColourAndTheNoticeColourHasAtLeast4_5To1Contrast() {
        let palette: [(String, NSColor)] = [
            ("perriApproved", AuthoredPrsPalette.perriApproved), ("perriMuted", AuthoredPrsPalette.perriMuted),
            ("perriChanges", AuthoredPrsPalette.perriChanges), ("warning", AuthoredPrsPalette.warning),
        ]
        for appearance in Self.appearances {
            for (name, color) in palette {
                let ratio = ContrastMath.ratio(color, over: AuthoredPrsPalette.background, in: appearance.name)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(name) over the background in \(appearance.label) is \(ratio):1")
            }
        }
        // And the colours the labels really use.
        eachRendering { r in
            if r.scenario.hasBadge, let color = r.row.perriLabel.textColor {
                let ratio = ContrastMath.ratio(color, over: AuthoredPrsPalette.background, in: r.appearance)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(r.context): the badge text is \(ratio):1")
            }
            if r.scenario.hasNotice, let color = r.row.noticeLabel.textColor {
                let ratio = ContrastMath.ratio(color, over: AuthoredPrsPalette.background, in: r.appearance)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(r.context): the notice text is \(ratio):1")
            }
        }
    }

    // MARK: - The Merge button

    func testTheMergeButtonSaysWhatItsModelSays() {
        eachRendering { r in
            guard let button = r.model.mergeButton else { return XCTFail("\(r.context): precondition, the row has a button") }
            XCTAssertFalse(r.row.mergeButton.isHidden, r.context)
            XCTAssertEqual(r.row.mergeButton.title, button.title, r.context)
            XCTAssertEqual(r.row.mergeButton.title, r.scenario.buttonTitle, r.context)
            XCTAssertEqual(r.row.mergeButton.isEnabled, button.isEnabled, r.context)
            XCTAssertEqual(r.row.mergeButton.isEnabled, r.scenario.isReady, r.context)
            XCTAssertEqual(r.row.mergeButton.toolTip, button.tooltip, r.context)
            XCTAssertEqual(r.row.mergeButton.accessibilityLabel(), button.accessibilityLabel, r.context)
        }
    }

    func testTheMergeButtonKeepsItsSizeAndPlaceInEveryState() {
        for appearance in Self.appearances {
            for width in Self.widths {
                var frames: [(Scenario, NSRect)] = []
                for scenario in Scenario.allCases {
                    guard let r = render(scenario, width: width, appearance: appearance) else { continue }
                    XCTAssertFalse(r.row.mergeButton.isHidden, r.context)
                    XCTAssertTrue(r.row.bounds.insetBy(dx: -0.5, dy: -0.5).contains(r.row.mergeButton.frame),
                                  "\(r.context): the button \(r.row.mergeButton.frame) is inside the row \(r.row.bounds)")
                    XCTAssertLessThanOrEqual(r.rect(r.row.mergeButton).maxX, r.width - AuthoredPrRowView.sidePadding + 0.5,
                                             "\(r.context): inside the row's right padding")
                    frames.append((scenario, r.row.mergeButton.frame))
                }
                // One width per way in: every state of a direct row, and every state of a queue row.
                for group in [frames.filter { !$0.0.isQueue }, frames.filter { $0.0.isQueue }] {
                guard let first = group.first else { continue }
                for (scenario, frame) in group {
                    let context = "'\(scenario.rawValue)' vs '\(first.0.rawValue)' at \(Int(width)) pt, \(appearance.label)"
                    XCTAssertEqual(frame.width, first.1.width, accuracy: 0.5, "\(context): the button's width jumped between states")
                    XCTAssertEqual(frame.height, first.1.height, accuracy: 0.5, "\(context): the button's height changed")
                    XCTAssertEqual(frame.maxX, first.1.maxX, accuracy: 0.5, "\(context): the button moved sideways")
                }
                }
            }
        }
    }

    /// Is `button`'s title (painted red) drawn whole, and at least 2 pt inside the button's frame on both sides?
    /// Returns a verdict rather than asserting, so a mutation test can demand that it fails.
    private func titleCheck(_ button: NSButton, title: String, host: NSView, bitmap: APT.Bitmap,
                            appearance: NSAppearance.Name) -> (ok: Bool, detail: String) {
        let frame = APT.rect(of: button, in: host)
        guard let ink = APT.redInk(bitmap, in: frame.insetBy(dx: -1.5, dy: -2)) else {
            return (false, "the title '\(title)' drew nothing in the button's frame \(frame)")
        }
        let font = button.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        guard let reference = APT.referenceInk(APT.attributed(title, font: font, color: APT.titleRed),
                                               appearance: appearance, scale: bitmap.scale) else {
            return (false, "could not draw the reference for '\(title)'")
        }
        var problems: [String] = []
        if ink.width < reference.width - bitmap.tolerance {
            problems.append("'\(title)' is clipped: ink \(ink.width) pt wide, whole is \(reference.width)")
        }
        if ink.minX < frame.minX + 2 {
            problems.append("'\(title)' starts \(ink.minX - frame.minX) pt inside the button's left edge (needs 2)")
        }
        if ink.maxX > frame.maxX - 2 {
            problems.append("'\(title)' ends \(frame.maxX - ink.maxX) pt inside the button's right edge (needs 2)")
        }
        return (problems.isEmpty, problems.joined(separator: "; "))
    }

    func testTheMergeButtonTitleIsDrawnWholeInEveryState() {
        eachRendering(measuringTitles: true) { r in
            XCTAssertFalse(r.row.mergeButton.isHidden, "\(r.context): precondition")
            let check = titleCheck(r.row.mergeButton, title: r.scenario.buttonTitle, host: r.host, bitmap: r.bitmap, appearance: r.appearance)
            XCTAssertTrue(check.ok, "\(r.context): \(check.detail)")
        }
    }

    func testMutationASqueezedMergeButtonFailsTheTitleCheck() {
        // The same measurement, fed a button squeezed to a width that cannot hold "Merging…": it must say not ok,
        // while the real button says ok.
        guard let r = render(.merging, width: 380, appearance: Self.appearances[0], measuringTitles: true) else { return }
        let real = titleCheck(r.row.mergeButton, title: "Merging…", host: r.host, bitmap: r.bitmap, appearance: r.appearance)
        XCTAssertTrue(real.ok, real.detail)

        let (host, window) = APT.inkHost(size: NSSize(width: 380, height: 60), appearance: .darkAqua)
        windows.append(window)
        let squeezed = NSButton(title: "Merging…", target: nil, action: nil)
        squeezed.bezelStyle = .rounded
        squeezed.controlSize = .small
        squeezed.font = r.row.mergeButton.font
        squeezed.lineBreakMode = .byClipping
        squeezed.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(squeezed)
        NSLayoutConstraint.activate([
            squeezed.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 20),
            squeezed.topAnchor.constraint(equalTo: host.topAnchor, constant: 10),
            squeezed.widthAnchor.constraint(equalToConstant: 28),
        ])
        APT.paintTitleRed(squeezed)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = APT.render(host) else { return }
        let broken = titleCheck(squeezed, title: "Merging…", host: host, bitmap: bitmap, appearance: .darkAqua)
        XCTAssertFalse(broken.ok, "the check must be able to fail: a 28 pt button cannot show 'Merging…'")
    }

    func testTheTellAndMergeButtonsAreNeverBothVisible() {
        // A row model that somehow carries both (a fixable row in READY would not, but the view must not trust that).
        var model = HF.row(HF.pr(group: .needsYou), handoff: true)
        model.mergeButton = MF.row(MF.readyPr()).mergeButton
        XCTAssertNotNil(model.tellButton, "precondition")
        XCTAssertNotNil(model.mergeButton, "precondition")
        for appearance in Self.appearances {
            guard let r = render(.ready, width: 380, appearance: appearance, model: model) else { continue }
            XCTAssertFalse(!r.row.tellButton.isHidden && !r.row.mergeButton.isHidden,
                           "\(r.context): both buttons are visible")
        }
    }

    // MARK: - Nothing overflows

    func testNothingInksPastTheRowsEdgeOrIntoTheMergeButton() {
        eachRendering { r in
            let first = r.rect(r.row.statusLabel).union(r.rect(r.row.repoChip))
            let checks = r.rect(r.row.checksLabel)
            let review = r.rect(r.row.reviewLabel)
            let last = NSRect(x: 0, y: review.maxY, width: r.width, height: AuthoredPrRowView.lineHeight)
            let bands: [(String, NSRect)] = [
                ("title line", NSRect(x: 0, y: first.minY, width: r.width, height: first.height)),
                ("checks line", NSRect(x: 0, y: checks.minY, width: r.width, height: checks.height)),
                ("review line", NSRect(x: 0, y: review.minY, width: r.width, height: review.height)),
                (r.scenario.hasNotice ? "notice line" : "owner line", last),
            ]
            for (name, band) in bands {
                guard let ink = r.bitmap.ink(in: band) else {
                    XCTFail("\(r.context): the \(name) drew nothing")
                    continue
                }
                XCTAssertLessThanOrEqual(ink.maxX, r.width - 2, "\(r.context): the \(name) reaches the row's right edge (ink ends at \(ink.maxX) of \(r.width))")
                XCTAssertGreaterThanOrEqual(ink.minX, 2, "\(r.context): the \(name) starts at the row's left edge")
            }
            // A line beside the button ends before it: nothing of the line in the gap just left of the button.
            guard !r.row.mergeButton.isHidden else { return }
            let button = r.rect(r.row.mergeButton)
            for (name, band) in bands where band.maxY > button.minY && band.minY < button.maxY {
                let gap = NSRect(x: button.minX - 6, y: band.minY, width: 4, height: band.height)
                XCTAssertNil(r.bitmap.ink(in: gap), "\(r.context): the \(name) runs up to or under the Merge button")
            }
        }
    }

    // MARK: - The title

    func testALongTitleStillEndsInAnEllipsisWithItsTooltip() {
        var truncated = 0
        eachRendering { r in
            let slot = r.rect(r.row.titleLabel)
            XCTAssertEqual(r.row.titleLabel.lineBreakMode, .byTruncatingTail, "\(r.context): the title truncates at the tail")
            XCTAssertEqual(r.row.titleLabel.stringValue, Self.title, "\(r.context): the label holds all 200 characters")
            XCTAssertEqual(r.row.titleLabel.toolTip, Self.title, "\(r.context): and the tooltip has them all")
            var nextLeft = r.rect(r.row.repoChip).minX
            if r.row.draftBadge.isHidden == false { nextLeft = min(nextLeft, r.rect(r.row.draftBadge).minX) }
            if !r.row.perriLabel.isHidden, r.rect(r.row.perriLabel).minY < slot.maxY, r.rect(r.row.perriLabel).maxY > slot.minY {
                nextLeft = min(nextLeft, r.rect(r.row.perriLabel).minX)
            }
            guard let ink = r.bitmap.ink(in: slot, threshold: 0.15) else { return XCTFail("\(r.context): the title drew nothing") }
            XCTAssertLessThanOrEqual(ink.maxX, nextLeft - 1, "\(r.context): the title's ink stops before what follows it")
            let text = APT.attributed(Self.title, font: .systemFont(ofSize: 12), color: AuthoredPrsPalette.text)
            guard text.size().width > slot.width else { return }
            truncated += 1
            guard let tail = r.bitmap.trailingInkHeight(in: slot) else { return XCTFail("\(r.context): no ink at the end of the title") }
            XCTAssertLessThan(tail, 5, "\(r.context): the title ends in something \(tail) pt tall: a clipped glyph, not an ellipsis")
        }
        XCTAssertGreaterThanOrEqual(truncated, Scenario.allCases.count * 4, "precondition: every rendering truncates its title")
    }

    // MARK: - The reason beside a disabled button

    func testTheReasonOnTheReviewLineIsVisibleAtTheNarrowWidths() {
        for appearance in Self.appearances {
            for width in Self.widths {
                let pr = MF.readyPr(124, draft: true)   // "Approved by dana · Draft": short enough to fit beside any button
                let model = AuthoredPrsPresentation.row(pr, now: APT.t0, perri: true, merge: true)
                guard let r = render(.ready, width: width, appearance: appearance, model: model) else { continue }
                XCTAssertEqual(r.row.reviewLabel.stringValue, "Approved by dana · Draft", r.context)
                assertWhole(r, r.row.reviewLabel, "the review line with its reason")
                XCTAssertFalse(r.row.mergeButton.isEnabled, r.context)
            }
        }
    }

    // MARK: - The notice

    func testTheNoticeTakesThePlaceOfTheOwnerLineAtTheSameHeight() {
        for appearance in Self.appearances {
            for width in Self.widths {
                guard let r = render(.notice, width: width, appearance: appearance),
                      let plain = render(.ready, width: width, appearance: appearance) else { continue }
                let notice = r.rect(r.row.noticeLabel)
                let review = r.rect(r.row.reviewLabel)
                XCTAssertFalse(r.row.noticeLabel.isHidden, "\(r.context): precondition")
                XCTAssertFalse(r.row.noticeDismissButton.isHidden, "\(r.context): precondition")
                XCTAssertEqual(notice.minY, review.maxY, accuracy: 1.0, "\(r.context): the notice is on the line under the review line, where the owner was")
                XCTAssertEqual(notice.height, AuthoredPrRowView.lineHeight, accuracy: 0.5, "\(r.context): one line high, like the owner line")
                XCTAssertEqual(r.row.frame.height, plain.row.frame.height, accuracy: 0.5, "\(r.context): the row did not grow")
                XCTAssertGreaterThanOrEqual(notice.minX, AuthoredPrRowView.sidePadding, "\(r.context): inside the row's left padding")
                XCTAssertLessThanOrEqual(notice.maxX, r.width - AuthoredPrRowView.sidePadding + 0.5, "\(r.context): inside the row's right padding")
                let dismiss = r.rect(r.row.noticeDismissButton)
                XCTAssertTrue(r.row.bounds.insetBy(dx: -0.5, dy: -0.5).contains(r.row.noticeDismissButton.frame), "\(r.context): the dismiss button is inside the row")
                XCTAssertFalse(notice.intersects(dismiss), "\(r.context): the notice and its dismiss button overlap")
                XCTAssertFalse(r.row.noticeDismissButton.accessibilityLabel()?.isEmpty ?? true, "\(r.context): the dismiss button has a name")

                // The owner line is gone, not drawn under the notice: all the ink on the line is the notice's or the button's.
                let band = NSRect(x: 0, y: review.maxY, width: r.width, height: AuthoredPrRowView.lineHeight)
                if let ink = r.bitmap.ink(in: band) {
                    let right = max(notice.maxX, dismiss.maxX)
                    XCTAssertGreaterThanOrEqual(ink.minX, notice.minX - 1.5, "\(r.context): something is drawn left of the notice")
                    XCTAssertLessThanOrEqual(ink.maxX, right + 1.5, "\(r.context): something is drawn right of the notice and its button")
                } else {
                    XCTFail("\(r.context): the notice line drew nothing")
                }
                for (name, view) in [("owner prefix", r.row.ownerPrefixLabel), ("owner job", r.row.jobButton),
                                     ("owner suffix", r.row.ownerSuffixLabel), ("base", r.row.baseLabel)] as [(String, NSView)] {
                    XCTAssertTrue(view.isHiddenOrHasHiddenAncestor, "\(r.context): the \(name) is still shown")
                }
                XCTAssertFalse(plain.row.ownerPrefixLabel.isHiddenOrHasHiddenAncestor, "\(plain.context): precondition, without a notice the owner line shows")
            }
        }
    }

    func testTheNoticeIsShownWholeOrCutWithItsFullTextInATooltip() {
        var cut = 0, whole = 0
        eachRendering { r in
            guard r.scenario.hasNotice else {
                XCTAssertTrue(r.row.noticeLabel.isHidden, "\(r.context): no notice")
                XCTAssertTrue(r.row.noticeDismissButton.isHidden, "\(r.context): no dismiss button")
                return
            }
            let text = r.scenario == .dropped ? "Dropped from the merge queue"
                : "Perri approved an older version: it needs a new review"
            XCTAssertEqual(r.row.noticeLabel.stringValue, text, r.context)
            XCTAssertEqual(r.model.mergeNotice, text, r.context)
            let frame = r.rect(r.row.noticeLabel)
            let attributed = APT.attributed(text, font: r.row.noticeLabel.font ?? .systemFont(ofSize: 11),
                                            color: r.row.noticeLabel.textColor ?? AuthoredPrsPalette.warning)
            if attributed.size().width <= frame.width {
                whole += 1
                assertWhole(r, r.row.noticeLabel, "the notice")
            } else {
                cut += 1
                XCTAssertEqual(r.row.noticeLabel.toolTip, text, "\(r.context): the notice is cut on screen, so its tooltip has all of it")
            }
            if let ink = r.bitmap.ink(in: grown(frame)) {
                XCTAssertLessThanOrEqual(ink.maxX, frame.maxX + 1, "\(r.context): the notice's ink runs past its label")
            }
            XCTAssertFalse(APT.hasLink(r.row.noticeLabel.attributedStringValue), "\(r.context): plain text")
        }
        XCTAssertGreaterThan(cut + whole, 0)
    }

    // MARK: - Height

    func testTheRowKeepsItsHeightInEveryState() {
        eachRendering { r in
            XCTAssertEqual(r.row.frame.width, r.width, accuracy: 0.5, r.context)
            XCTAssertEqual(r.row.frame.height, AuthoredPrRowView.rowHeight, accuracy: 0.5, "\(r.context): the laid-out height")
            XCTAssertEqual(r.row.fittingSize.height, AuthoredPrRowView.rowHeight, accuracy: 0.5, "\(r.context): the fitting height")
        }
    }

    // MARK: - VoiceOver

    func testVoiceOverGetsTheRowsWordsAndTheRightActionsInEveryState() throws {
        try eachRendering { r in
            XCTAssertEqual(r.row.accessibilityLabel(), r.model.accessibilityLabel, "\(r.context): the label is the whole row in words")
            XCTAssertTrue(r.row.isAccessibilityElement(), r.context)
            if let badge = r.model.perriBadge {
                XCTAssertTrue(try XCTUnwrap(r.row.accessibilityLabel()).contains(", \(badge.accessibilityLabel)"), "\(r.context): VoiceOver hears the verdict")
            }
            if let notice = r.model.mergeNotice {
                XCTAssertTrue(try XCTUnwrap(r.row.accessibilityLabel()).hasSuffix(", merge failed: \(notice)"), "\(r.context): and the failure")
            }

            let names = Set((r.row.accessibilityCustomActions() ?? []).map(\.name))
            XCTAssertEqual(names.contains(r.scenario.buttonTitle), r.scenario.isReady, "\(r.context): a Merge (or Add to merge queue) action only while the button is ready, named as the button is: \(names)")
            XCTAssertEqual(!names.isDisjoint(with: ["Merge", "Add to merge queue"]), r.scenario.isReady, "\(r.context): \(names)")
            XCTAssertEqual(names.contains("Dismiss merge message"), r.scenario.hasNotice, "\(r.context): a dismiss action only with a notice: \(names)")
            XCTAssertTrue(names.contains("Show Mother job a1b2c3"), "\(r.context): the existing action stays: \(names)")
        }
    }

    func testTheActionsCallTheRowsCallbacksWithItsModel() throws {
        guard let r = render(.notice, width: 380, appearance: Self.appearances[0]) else { return }
        var merged: [String] = [], dismissed: [String] = []
        r.row.onMerge = { merged.append($0.id) }
        r.row.onDismissMergeNotice = { dismissed.append($0.id) }
        let actions = r.row.accessibilityCustomActions() ?? []

        XCTAssertTrue(try XCTUnwrap(actions.first { $0.name == "Merge" }).handler?() ?? false)
        XCTAssertEqual(merged, [r.model.id])
        XCTAssertTrue(dismissed.isEmpty)
        XCTAssertTrue(try XCTUnwrap(actions.first { $0.name == "Dismiss merge message" }).handler?() ?? false)
        XCTAssertEqual(dismissed, [r.model.id])
        XCTAssertEqual(merged, [r.model.id], "dismissing does not merge")

        r.row.mergeButton.performClick(nil)
        XCTAssertEqual(merged, [r.model.id, r.model.id], "the button calls onMerge too")
        r.row.noticeDismissButton.performClick(nil)
        XCTAssertEqual(dismissed, [r.model.id, r.model.id], "and the dismiss button calls onDismissMergeNotice")
    }

    func testARowWithNoMergeStateHasNoMergeControlsAndNoMergeActions() throws {
        let plain = AuthoredPrsPresentation.row(MF.readyPr(125, group: .waiting), now: APT.t0, perri: true, merge: true)
        for appearance in Self.appearances {
            guard let r = render(.ready, width: 320, appearance: appearance, model: plain) else { continue }
            XCTAssertTrue(r.row.mergeButton.isHidden, r.context)
            XCTAssertTrue(r.row.noticeLabel.isHidden, r.context)
            XCTAssertTrue(r.row.noticeDismissButton.isHidden, r.context)
            let names = (r.row.accessibilityCustomActions() ?? []).map(\.name)
            XCTAssertFalse(names.contains("Merge") || names.contains("Dismiss merge message"), "\(r.context): \(names)")
        }
    }

    // MARK: - The merge queue

    func testTheQueueStatesNameThemselvesAndKeepTheRowsHeightAndTheButtonsWidth() {
        for appearance in Self.appearances {
            for width in Self.widths {
                let base = render(.queueReady, width: width, appearance: appearance)
                for scenario in [Scenario.queueReady, .queueNeedsUpdate, .adding, .inQueue, .inQueueAtPosition, .dropped] {
                    guard let r = render(scenario, width: width, appearance: appearance), let base else { continue }
                    XCTAssertEqual(r.row.mergeButton.title, r.model.mergeButton?.title, r.context)
                    XCTAssertEqual(r.row.mergeButton.title, scenario.buttonTitle, r.context)
                    XCTAssertEqual(r.row.mergeButton.isEnabled, scenario.isReady, r.context)
                    XCTAssertEqual(r.row.mergeButton.accessibilityLabel(), r.model.mergeButton?.accessibilityLabel, r.context)
                    XCTAssertEqual(r.row.frame.height, AuthoredPrRowView.rowHeight, accuracy: 0.5, "\(r.context): no row-height jump")
                    XCTAssertEqual(r.row.fittingSize.height, AuthoredPrRowView.rowHeight, accuracy: 0.5, r.context)
                    XCTAssertEqual(r.row.mergeButton.frame.width, base.row.mergeButton.frame.width, accuracy: 0.5,
                                   "\(r.context): the button's width jumped")
                    XCTAssertEqual(r.row.mergeButton.frame.maxX, base.row.mergeButton.frame.maxX, accuracy: 0.5, r.context)
                    XCTAssertEqual(r.row.noticeLabel.stringValue, scenario == .dropped ? "Dropped from the merge queue" : "", r.context)
                }
            }
        }
    }

    func testTheLongestQueueTitleIsDrawnWholeInsideTheButton() {
        for scenario in [Scenario.queueReady, .inQueueAtPosition] {
            for appearance in Self.appearances {
                for width in Self.widths {
                    guard let r = render(scenario, width: width, appearance: appearance, measuringTitles: true) else { continue }
                    let check = titleCheck(r.row.mergeButton, title: scenario.buttonTitle, host: r.host, bitmap: r.bitmap,
                                           appearance: r.appearance)
                    XCTAssertTrue(check.ok, "\(r.context): \(check.detail)")
                }
            }
        }
    }

    func testAQueueRowThatWillNotBeEnqueuedIsOffAndSaysWhy() throws {
        guard let r = render(.queueNeedsUpdate, width: 380, appearance: Self.appearances[0]) else { return }
        XCTAssertFalse(r.row.mergeButton.isEnabled)
        XCTAssertTrue(r.model.reviewLine.contains("Update Nostromo to merge into a merge queue"), r.model.reviewLine)
        XCTAssertTrue((r.row.accessibilityCustomActions() ?? []).allSatisfy { $0.name != "Merge" && $0.name != "Add to merge queue" })
    }
}
