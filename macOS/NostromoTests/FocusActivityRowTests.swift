import XCTest
import AppKit
import Combine
import NostromoKit

// The quiet mark at the leading edge of a sidebar focus row.
//
// A row shows, left of the focus name and in a RESERVED slot, one of: nothing; a hollow ring (activity
// since the operator last looked); a filled dot (unread responses, tooltip carries the count); a filled
// dot with a small "!" cut out (a problem). The slot is reserved whether or not a mark shows, so the name
// and the second line sit further right than they used to and NEVER move when a mark comes or goes.
//
// Sections:
//   FocusActivityRowDrawingTests  one row hosted as in NeedsYouPillsTests: what is drawn (read from the real
//                                 layers) in both appearances and every highlight, tooltip, accessibility
//                                 label composition, built-in rows, a narrow-width sweep;
//   FocusActivityRowSidebarTests  the REAL path: buildNavRows -> TabBarView.setFocuses in a laid-out window,
//                                 the real NavTabItem instances found in the view tree; flipping the provider
//                                 and calling refreshActivity() moves nothing, rebuilds nothing, and the slot
//                                 sits where the geometry says it must;
//   FocusActivityColorTests       the colours and their WCAG non-text contrast on every row backdrop.
//
// Logic test (no host app, no `@testable import`): the app sources are compiled into this target directly.
// Nothing touches the standard defaults: the end-to-end test through `AppStore.shared` swaps in a coordinator
// on a private suite and restores the original in tearDown.
//
// Mutations caught here:
//   (3) the mark in the wrong slot (right of the name, overlapping it, or its frame depending on the state)
//       -> testTheSlotIsExactlyFourPointsLeftOfTheNameCenteredOnItAndTheSameForEveryState,
//          testTheNameAndSecondLineMoveTenPointsRightAndStayThere, testTheSlotNeverTouchesAnythingElseInARealRow,
//          testFlippingTheMarkNeverMovesAnythingInTheRealRows, testNarrowRowsNeverLetTheSlotOverlapTheName
//   (4) UNREAD losing to ACTIVITY is a model rule: see FocusActivityModelTests and FocusActivityCoordinatorTests.

// MARK: - Shared helpers

private struct RGBA { var r: Double, g: Double, b: Double, a: Double }

private func rgba(_ color: NSColor) throws -> RGBA {
    let c = try XCTUnwrap(color.usingColorSpace(.sRGB), "colour has no sRGB form")
    return RGBA(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent), a: Double(c.alphaComponent))
}

private func over(_ top: NSColor, _ bottom: NSColor) throws -> NSColor {
    let t = try rgba(top), b = try rgba(bottom)
    func mix(_ x: Double, _ y: Double) -> CGFloat { CGFloat(x * t.a + y * (1 - t.a)) }
    return NSColor(srgbRed: mix(t.r, b.r), green: mix(t.g, b.g), blue: mix(t.b, b.b), alpha: 1)
}

private func luminance(_ color: NSColor) throws -> Double {
    let c = try rgba(color)
    func lin(_ v: Double) -> Double { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
    return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
}

private func contrast(_ a: NSColor, _ b: NSColor) throws -> Double {
    let la = try luminance(a), lb = try luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
}

private func assertSameColor(_ actual: CGColor?, _ expected: NSColor, _ message: String = "",
                             file: StaticString = #filePath, line: UInt = #line) throws {
    let nsActual = try XCTUnwrap(actual.flatMap { NSColor(cgColor: $0) }, "colour is nil. \(message)", file: file, line: line)
    let got = try rgba(nsActual), want = try rgba(expected)
    XCTAssertEqual(got.r, want.r, accuracy: 0.005, "red. \(message)", file: file, line: line)
    XCTAssertEqual(got.g, want.g, accuracy: 0.005, "green. \(message)", file: file, line: line)
    XCTAssertEqual(got.b, want.b, accuracy: 0.005, "blue. \(message)", file: file, line: line)
    XCTAssertEqual(got.a, want.a, accuracy: 0.005, "alpha. \(message)", file: file, line: line)
}

private func assertSameRect(_ a: NSRect, _ b: NSRect, _ message: @autoclosure () -> String,
                            file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.origin.x, b.origin.x, accuracy: 0.01, "x: \(message())", file: file, line: line)
    XCTAssertEqual(a.origin.y, b.origin.y, accuracy: 0.01, "y: \(message())", file: file, line: line)
    XCTAssertEqual(a.size.width, b.size.width, accuracy: 0.01, "width: \(message())", file: file, line: line)
    XCTAssertEqual(a.size.height, b.size.height, accuracy: 0.01, "height: \(message())", file: file, line: line)
}

private func assertSameOptionalRect(_ a: NSRect?, _ b: NSRect?, _ message: @autoclosure () -> String,
                                    file: StaticString = #filePath, line: UInt = #line) {
    switch (a, b) {
    case (nil, nil): break
    case let (x?, y?): assertSameRect(x, y, message(), file: file, line: line)
    default: XCTFail("one is nil and the other is not: \(message())", file: file, line: line)
    }
}

/// Every state the mark can be in, with the unread counts the spec calls out.
private let allStates: [(String, FocusActivityState)] = [
    ("none", .none),
    ("activity", .activity),
    ("unread 1", .unread(count: 1)),
    ("unread 99", .unread(count: 99)),
    ("unread 100000", .unread(count: 100_000)),
    ("problem crashed", .problem(.crashed)),
    ("problem unknown kind", .problem(nil)),
]

private let shownStates: [(String, FocusActivityState)] = allStates.filter { $0.1 != FocusActivityState.none }

private let appearances: [NSAppearance.Name] = [.aqua, .darkAqua]

// MARK: - One row: drawing, tooltip, accessibility

final class FocusActivityRowDrawingTests: XCTestCase {

    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.forEach { $0.close() }
        windows = []
        super.tearDown()
    }

    private static func dynamicFocus() -> Focus {
        Focus(id: "22222222-bbbb", agentTag: "cody", projectPath: "/Users/hammer/Code/nostromo", isBuiltIn: false, org: "Carefeed")
    }

    private func builtIn(_ tag: String) -> Focus { Focus.builtIns.first { $0.agentTag == tag }! }

    /// A row hosted pinned as `TabBarView` pins one (required width and height, leading and top to its
    /// container) in an off-screen window. Layout facts (heights, real constraints) are asserted separately
    /// through the real `TabBarView` path below; this rig is for drawing, tooltips and labels.
    private func makeItem(focus: Focus? = nil, label: String = "Cody in Nostromo", branch: String = "main",
                          width: CGFloat = Theme.sidebarWidth, indented: Bool = false) -> NavTabItem {
        let item = NavTabItem(focus: focus ?? Self.dynamicFocus(), label: label, secondary: branch, indented: indented)
        let height = Theme.navItemSubtitleHeight
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height + 20),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        windows.append(window)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height + 20))
        window.contentView = host
        item.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(item)
        NSLayoutConstraint.activate([
            item.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            item.topAnchor.constraint(equalTo: host.topAnchor),
            item.widthAnchor.constraint(equalToConstant: width),
            item.heightAnchor.constraint(equalToConstant: height),
        ])
        host.layoutSubtreeIfNeeded()
        return item
    }

    private func relayout(_ item: NavTabItem) { (item.superview ?? item).layoutSubtreeIfNeeded() }

    private func show(_ item: NavTabItem, _ state: FocusActivityState) {
        item.setActivity(state)
        relayout(item)
    }

    // MARK: What is drawn

    private func assertDrawn(_ item: NavTabItem, _ state: FocusActivityState, _ context: String,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(item.activityState, state, context, file: file, line: line)
        switch state {
        case .none:
            XCTAssertNil(item.drawnActivityMark, "nothing is drawn: \(context)", file: file, line: line)
            XCTAssertNil(item.activityMarkFrame, "no mark frame: \(context)", file: file, line: line)
            XCTAssertNil(item.activityToolTip, "no tooltip: \(context)", file: file, line: line)
            return
        default: break
        }
        let mark = try XCTUnwrap(item.drawnActivityMark, "a mark is drawn: \(context)", file: file, line: line)
        XCTAssertEqual(mark.size, CGSize(width: 8, height: 8), "8 x 8: \(context)", file: file, line: line)
        XCTAssertEqual(item.activityMarkFrame, item.activitySlotFrame, "the mark sits in the slot: \(context)", file: file, line: line)
        switch state {
        case .activity:
            XCTAssertEqual(mark.shape, .ring, context, file: file, line: line)
            if let fill = mark.fill { XCTAssertEqual(fill.alpha, 0, accuracy: 0.001, "a ring is hollow: \(context)", file: file, line: line) }
            try assertSameColor(mark.stroke, Theme.focusMark, "ring stroke: \(context)", file: file, line: line)
            XCTAssertGreaterThan(mark.strokeWidth, 0, "the ring has a visible outline: \(context)", file: file, line: line)
            XCTAssertNil(mark.glyph, "a ring has no glyph: \(context)", file: file, line: line)
        case .unread:
            XCTAssertEqual(mark.shape, .dot, context, file: file, line: line)
            try assertSameColor(mark.fill, Theme.focusMark, "dot fill: \(context)", file: file, line: line)
            XCTAssertEqual(mark.strokeWidth, 0, accuracy: 0.001, "a dot has no outline: \(context)", file: file, line: line)
            XCTAssertNil(mark.glyph, "a plain dot has no glyph: \(context)", file: file, line: line)
        case .problem:
            XCTAssertEqual(mark.shape, .warningDot, context, file: file, line: line)
            try assertSameColor(mark.fill, Theme.focusMarkProblem, "problem dot fill: \(context)", file: file, line: line)
            try assertSameColor(mark.glyph, Theme.focusMarkGlyph, "the cut-out '!': \(context)", file: file, line: line)
        case .none:
            break
        }
        XCTAssertEqual(item.activityToolTip, state.toolTip, "tooltip is the state's: \(context)", file: file, line: line)
        XCTAssertFalse(item.activityMarkIsAccessibilityElement, "the mark view is never its own element: \(context)", file: file, line: line)
    }

    private struct Highlight {
        let name: String
        let active: Bool
        let blocking: Int
        let waiting: Int
    }

    private let highlights: [Highlight] = [
        Highlight(name: "plain row", active: false, blocking: 0, waiting: 0),
        Highlight(name: "active row", active: true, blocking: 0, waiting: 0),
        Highlight(name: "blocking pill (red row)", active: false, blocking: 2, waiting: 0),
        Highlight(name: "waiting pill (amber)", active: false, blocking: 0, waiting: 7),
        Highlight(name: "active and blocking", active: true, blocking: 2, waiting: 0),
        Highlight(name: "both pills, active", active: true, blocking: 2, waiting: 7),
    ]

    private func configure(_ item: NavTabItem, _ h: Highlight) {
        item.isActive = h.active
        if h.blocking == 0 && h.waiting == 0 { item.setBadge(nil) }
        else { item.setBadge(FocusBadge.needsYou(blocking: h.blocking, waiting: h.waiting)) }
        relayout(item)
    }

    func testEveryStateIsDrawnAsSpecifiedInBothAppearancesAndEveryHighlight() throws {
        for name in appearances {
            for h in highlights {
                let item = makeItem()
                item.appearance = try XCTUnwrap(NSAppearance(named: name))
                configure(item, h)
                // Forward, then backward, so a layer left over from the previous state would show.
                for (label, state) in allStates + allStates.reversed() {
                    show(item, state)
                    try assertDrawn(item, state, "\(label), \(h.name), \(name.rawValue)")
                }
            }
        }
    }

    func testTheMarkLooksTheSameWhateverTheRowsHighlight() throws {
        for (label, state) in shownStates {
            var seen: [NavTabItem.DrawnActivityMark] = []
            for name in appearances {
                for h in highlights {
                    let item = makeItem()
                    item.appearance = try XCTUnwrap(NSAppearance(named: name))
                    configure(item, h)
                    show(item, state)
                    seen.append(try XCTUnwrap(item.drawnActivityMark, "\(label), \(h.name), \(name.rawValue)"))
                }
            }
            XCTAssertTrue(seen.dropFirst().allSatisfy { $0 == seen[0] }, "\(label): the mark is a fixed colour, not tinted by the row")
        }
    }

    func testTheThreeShapesAreDistinguishableFromEachOther() throws {
        let item = makeItem()
        var shapes: [NavTabItem.DrawnActivityMark.Shape] = []
        for state in [FocusActivityState.activity, .unread(count: 1), .problem(.crashed)] {
            show(item, state)
            shapes.append(try XCTUnwrap(item.drawnActivityMark).shape)
        }
        XCTAssertEqual(Set(shapes.map { "\($0)" }).count, 3, "ring, dot and warning dot read differently without colour")
    }

    func testTheMarkIsStillDrawnNextToARedBlockingPillAndAnAmberWaitingPill() throws {
        let item = makeItem()
        item.setBadge(FocusBadge.needsYou(blocking: 2, waiting: 7))
        relayout(item)
        show(item, .unread(count: 3))
        let mark = try XCTUnwrap(item.drawnActivityMark)
        XCTAssertEqual(mark.shape, .dot)
        XCTAssertEqual(item.blockingPillText, "2")
        XCTAssertEqual(item.waitingPillText, "7")
        let slot = item.activitySlotFrame
        XCTAssertFalse(slot.intersects(try XCTUnwrap(item.blockingPillFrame)))
        XCTAssertFalse(slot.intersects(try XCTUnwrap(item.waitingPillFrame)))
    }

    func testSettingTheSameStateTwiceAndClearingItAreStable() throws {
        let item = makeItem()
        show(item, .unread(count: 4))
        let first = item.drawnActivityMark
        show(item, .unread(count: 4))
        XCTAssertEqual(item.drawnActivityMark, first)
        show(item, .unread(count: 5))
        XCTAssertEqual(item.drawnActivityMark, first, "the count is in the tooltip, not the drawing")
        XCTAssertEqual(item.activityToolTip, "5 new messages")
        show(item, .none)
        XCTAssertNil(item.drawnActivityMark)
        show(item, .none)
        XCTAssertNil(item.drawnActivityMark)
    }

    // MARK: Where the slot is

    func testTheSlotIsExactlyFourPointsLeftOfTheNameCenteredOnItAndTheSameForEveryState() {
        for indented in [false, true] {
            for width in [Theme.sidebarWidth, 140] {
                let item = makeItem(width: width, indented: indented)
                let at = "indented \(indented), \(Int(width)) pt"
                let baseline = item.activitySlotFrame
                XCTAssertEqual(baseline.width, 8, at)
                XCTAssertEqual(baseline.height, 8, at)
                XCTAssertEqual(baseline.maxX, item.nameAlignmentFrame.minX - 4, accuracy: 0.01, "4 pt left of the name: \(at)")
                XCTAssertEqual(baseline.midY, item.nameAlignmentFrame.midY, accuracy: 0.51, "centred on the name's line: \(at)")
                XCTAssertLessThan(baseline.maxX, item.labelFrame.minX, "left of the name, not on or right of it: \(at)")
                for (label, state) in allStates {
                    show(item, state)
                    assertSameRect(item.activitySlotFrame, baseline, "the slot does not depend on the state (\(label)): \(at)")
                    XCTAssertEqual(item.activitySlotFrame.maxX, item.nameAlignmentFrame.minX - 4, accuracy: 0.01, "\(label): \(at)")
                }
            }
        }
    }

    func testTheNameAndSecondLineMoveTenPointsRightAndStayThere() throws {
        XCTAssertEqual(NavTabItem.activitySlotWidth, 10)
        // Before the mark existed the name's FRAME started at 7 (3 for the bar, 6 for the inset, less the text
        // field's own 2 pt padding), 19 when indented under a repo header.
        for (indented, was) in [(false, CGFloat(7)), (true, CGFloat(19))] {
            for (label, state) in allStates {
                let item = makeItem(indented: indented)
                show(item, state)
                XCTAssertEqual(item.labelFrame.minX, was + NavTabItem.activitySlotWidth, accuracy: 0.01,
                               "name, indented \(indented), \(label)")
                let second = try XCTUnwrap(item.secondaryFrame)
                XCTAssertEqual(second.minX, was + NavTabItem.activitySlotWidth, accuracy: 0.01,
                               "second line, indented \(indented), \(label)")
            }
        }
    }

    func testTheSlotClearsTheLeadingHighlightBarsOnEveryRow() {
        for indented in [false, true] {
            let item = makeItem(indented: indented)
            XCTAssertGreaterThanOrEqual(item.activitySlotFrame.minX, 6, "the two 3 pt bars take x < 6 (indented \(indented))")
            XCTAssertGreaterThanOrEqual(item.activitySlotFrame.minY, 0)
            XCTAssertLessThanOrEqual(item.activitySlotFrame.maxY, item.bounds.height)
        }
    }

    // MARK: Narrow widths

    func testNarrowRowsNeverLetTheSlotOverlapTheName() {
        for width in stride(from: CGFloat(200), through: 60, by: -10) {
            for indented in [false, true] {
                for withPills in [false, true] {
                    let reference = makeItem(width: width, indented: indented)
                    let item = makeItem(width: width, indented: indented)
                    if withPills {
                        reference.setBadge(FocusBadge.needsYou(blocking: 2, waiting: 7)); relayout(reference)
                        item.setBadge(FocusBadge.needsYou(blocking: 2, waiting: 7)); relayout(item)
                    }
                    let referenceLabel = reference.labelFrame
                    let referenceSecond = reference.secondaryFrame
                    let referenceSlot = reference.activitySlotFrame
                    for (label, state) in shownStates + [("none", FocusActivityState.none)] {
                        show(item, state)
                        let at = "\(label), \(Int(width)) pt, indented \(indented), pills \(withPills)"
                        assertSameRect(item.labelFrame, referenceLabel, "the name did not move: \(at)")
                        assertSameOptionalRect(item.secondaryFrame, referenceSecond, "the second line did not move: \(at)")
                        assertSameRect(item.activitySlotFrame, referenceSlot, "the slot did not move: \(at)")
                        XCTAssertFalse(item.activitySlotFrame.intersects(item.labelFrame), "slot overlaps the name: \(at)")
                        XCTAssertLessThanOrEqual(item.activitySlotFrame.maxX, item.nameAlignmentFrame.minX - 4 + 0.01, at)
                        XCTAssertGreaterThanOrEqual(item.activitySlotFrame.minX, 0, "slot inside the row: \(at)")
                        if let second = item.secondaryFrame {
                            XCTAssertFalse(item.activitySlotFrame.intersects(second), "slot overlaps the second line: \(at)")
                        }
                    }
                }
            }
        }
    }

    // MARK: Built-in rows keep their own pill

    func testABuiltInRowsMarkSitsBesideItsOwnPillWithoutMovingEitherOrTheName() throws {
        for focus in Focus.builtIns {
            let tag = focus.agentTag
            let plain = makeItem(focus: focus, label: tag.capitalized)
            plain.setBadge(FocusBadge(pill: "12", accessibilityLabel: "\(tag), 12"))
            relayout(plain)
            let pill = try XCTUnwrap(plain.pillFrame, tag)

            for (label, state) in shownStates {
                let item = makeItem(focus: focus, label: tag.capitalized)
                item.setBadge(FocusBadge(pill: "12", accessibilityLabel: "\(tag), 12"))
                show(item, state)
                XCTAssertEqual(item.pillText, "12", "\(tag) \(label)")
                assertSameRect(try XCTUnwrap(item.pillFrame), pill, "own pill of \(tag), \(label)")
                assertSameRect(item.labelFrame, plain.labelFrame, "name of \(tag), \(label)")
                assertSameOptionalRect(item.secondaryFrame, plain.secondaryFrame, "second line of \(tag), \(label)")
                XCTAssertFalse(item.activitySlotFrame.intersects(try XCTUnwrap(item.pillFrame)), "\(tag) \(label)")
                XCTAssertLessThan(item.activitySlotFrame.maxX, item.pillFrame!.minX, "the mark is at the other end from the pill")
                XCTAssertNotNil(item.drawnActivityMark, "\(tag) \(label)")
            }
        }
    }

    func testTheBuiltInsAreTheFiveTheSpecNames() {
        XCTAssertEqual(Set(Focus.builtIns.map(\.agentTag)), ["fred", "mother", "perri", "teri", "huey"])
    }

    // MARK: Tooltip

    func testTheTooltipSaysWhatTheMarkMeans() {
        let cases: [(FocusActivityState, String?)] = [
            (.none, nil),
            (.activity, "Activity since you last looked"),
            (.unread(count: 1), "1 new message"),
            (.unread(count: 3), "3 new messages"),
            (.unread(count: 100_000), "100000 new messages"),
            (.problem(.crashed), "Problem: the session crashed"),
            (.problem(.rateLimited), "Problem: a turn hit a usage limit"),
            (.problem(nil), "Problem: something went wrong"),
        ]
        for (state, tip) in cases {
            let item = makeItem()
            show(item, state)
            XCTAssertEqual(item.activityToolTip, tip, "\(state)")
        }
    }

    func testTheTooltipFollowsTheState() {
        let item = makeItem()
        show(item, .unread(count: 3))
        XCTAssertEqual(item.activityToolTip, "3 new messages")
        show(item, .problem(.crashed))
        XCTAssertEqual(item.activityToolTip, "Problem: the session crashed")
        show(item, .unread(count: 4))
        XCTAssertEqual(item.activityToolTip, "4 new messages")
        show(item, .none)
        XCTAssertNil(item.activityToolTip)
    }

    // MARK: Accessibility

    private let attentionBadge = FocusBadge(pill: "1", detail: "1 awaiting", level: .attention, accessibilityLabel: "Mother, 1 awaiting")

    func testTheMarkViewIsNeverItsOwnAccessibilityElement() {
        let item = makeItem()
        for (label, state) in allStates {
            show(item, state)
            XCTAssertFalse(item.activityMarkIsAccessibilityElement, label)
        }
    }

    func testARowWithNoBadgeAndNoActivityAddsNothingToItsAccessibility() {
        // A regular focus row is always one element labelled with its name (#448); a built-in row with
        // nothing to say is not an element. Neither says anything about activity.
        let item = makeItem()
        XCTAssertTrue(item.isAccessibilityElement())
        XCTAssertEqual(item.accessibilityLabel(), "Cody in Nostromo")
        show(item, .none)
        XCTAssertTrue(item.isAccessibilityElement())
        XCTAssertEqual(item.accessibilityLabel(), "Cody in Nostromo")

        let builtIn = makeItem(focus: builtIn("mother"), label: "Mother")
        show(builtIn, .none)
        XCTAssertFalse(builtIn.isAccessibilityElement())
        XCTAssertNil(builtIn.accessibilityLabel())
    }

    func testABadgeAloneKeepsItsLabelExactlyAsBefore() {
        let item = makeItem(focus: builtIn("mother"), label: "Mother")
        item.setBadge(attentionBadge)
        XCTAssertTrue(item.isAccessibilityElement())
        XCTAssertEqual(item.accessibilityLabel(), "Mother, 1 awaiting, needs your attention")

        let pills = makeItem()
        pills.setBadge(FocusBadge.needsYou(blocking: 2, waiting: 7))
        XCTAssertEqual(pills.accessibilityLabel(), "2 approvals blocking, 7 items waiting")
    }

    func testActivityAloneMakesTheRowAButtonThatReadsItsNameAndThePhrase() {
        let cases: [(FocusActivityState, String)] = [
            (.activity, "Cody in Nostromo, activity since you last looked"),
            (.unread(count: 1), "Cody in Nostromo, unread response"),
            (.unread(count: 3), "Cody in Nostromo, 3 unread responses"),
            (.problem(.crashed), "Cody in Nostromo, problem: the session crashed"),
            (.problem(nil), "Cody in Nostromo, problem: something went wrong"),
        ]
        for (state, label) in cases {
            let item = makeItem(label: "Cody in Nostromo")
            show(item, state)
            XCTAssertTrue(item.isAccessibilityElement(), "\(state)")
            XCTAssertEqual(item.accessibilityRole(), .button, "\(state)")
            XCTAssertEqual(item.accessibilityLabel(), label, "\(state)")
        }
    }

    func testTheActivityLabelUsesTheRowsCurrentName() {
        let item = makeItem(label: "Cody in Nostromo")
        show(item, .unread(count: 2))
        item.displayOverride = "Renamed focus"
        XCTAssertEqual(item.accessibilityLabel(), "Renamed focus, 2 unread responses")
    }

    func testABadgeAndActivityReadTheBadgeFirstThenThePhrase() {
        let item = makeItem()
        item.setBadge(FocusBadge.needsYou(blocking: 2, waiting: 7))
        show(item, .unread(count: 3))
        XCTAssertEqual(item.accessibilityLabel(), "2 approvals blocking, 7 items waiting, 3 unread responses")
        XCTAssertTrue(item.isAccessibilityElement())
        XCTAssertEqual(item.accessibilityRole(), .button)

        let attention = makeItem(focus: builtIn("mother"), label: "Mother")
        attention.setBadge(attentionBadge)
        show(attention, .problem(.apiError))
        XCTAssertEqual(attention.accessibilityLabel(),
                       "Mother, 1 awaiting, needs your attention, problem: a turn ended on an API error",
                       "the badge's own attention suffix stays with the badge")
    }

    func testTheLabelDoesNotDependOnWhichOfBadgeAndActivityWasSetFirst() {
        let badgeFirst = makeItem()
        badgeFirst.setBadge(FocusBadge.needsYou(blocking: 2, waiting: 7))
        show(badgeFirst, .unread(count: 3))

        let activityFirst = makeItem()
        show(activityFirst, .unread(count: 3))
        activityFirst.setBadge(FocusBadge.needsYou(blocking: 2, waiting: 7))

        XCTAssertEqual(activityFirst.accessibilityLabel(), badgeFirst.accessibilityLabel())
        XCTAssertEqual(activityFirst.accessibilityLabel(), "2 approvals blocking, 7 items waiting, 3 unread responses")
    }

    func testClearingActivityRestoresTheBadgeOnlyLabelExactly() {
        let item = makeItem(focus: builtIn("mother"), label: "Mother")
        item.setBadge(attentionBadge)
        let badgeOnly = item.accessibilityLabel()
        show(item, .unread(count: 3))
        XCTAssertNotEqual(item.accessibilityLabel(), badgeOnly)
        show(item, .none)
        XCTAssertEqual(item.accessibilityLabel(), badgeOnly)
        XCTAssertEqual(item.accessibilityLabel(), "Mother, 1 awaiting, needs your attention")
        XCTAssertTrue(item.isAccessibilityElement())
    }

    func testClearingTheBadgeWhileActivityRemainsLeavesTheActivityLabelAlone() {
        let item = makeItem(label: "Cody in Nostromo")
        item.setBadge(FocusBadge.needsYou(blocking: 2, waiting: 7))
        show(item, .unread(count: 3))
        item.setBadge(nil)
        XCTAssertTrue(item.isAccessibilityElement())
        XCTAssertEqual(item.accessibilityLabel(), "Cody in Nostromo, 3 unread responses")
    }

    func testClearingBothRestoresTheRowsPlainAccessibility() {
        // Regular row: back to one element labelled with its name. Built-in row: back to a non-element.
        for (focus, label, plainIsElement) in [(Optional<Focus>.none, "Cody in Nostromo", true),
                                               (Optional(builtIn("mother")), "Mother", false)] {
            let item = makeItem(focus: focus, label: label)
            item.setBadge(FocusBadge.needsYou(blocking: 2, waiting: 7))
            show(item, .activity)
            show(item, .none)
            item.setBadge(nil)
            XCTAssertEqual(item.isAccessibilityElement(), plainIsElement, label)
            XCTAssertEqual(item.accessibilityLabel(), plainIsElement ? label : nil, label)

            let other = makeItem(focus: focus, label: label)
            show(other, .activity)
            other.setBadge(FocusBadge.needsYou(blocking: 1, waiting: 0))
            other.setBadge(nil)
            show(other, .none)
            XCTAssertEqual(other.isAccessibilityElement(), plainIsElement, label)
            XCTAssertEqual(other.accessibilityLabel(), plainIsElement ? label : nil, label)
        }
    }

    func testTheLabelFollowsTheStateAsItChanges() {
        let item = makeItem(label: "Cody in Nostromo")
        show(item, .activity)
        XCTAssertEqual(item.accessibilityLabel(), "Cody in Nostromo, activity since you last looked")
        show(item, .unread(count: 1))
        XCTAssertEqual(item.accessibilityLabel(), "Cody in Nostromo, unread response")
        show(item, .problem(.stopped))
        XCTAssertEqual(item.accessibilityLabel(), "Cody in Nostromo, problem: the session was stopped")
    }
}

// MARK: - The real rows in a real TabBarView

final class FocusActivityRowSidebarTests: XCTestCase {

    private final class FixedWindow: NSWindow {
        override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    }

    /// What the provider answers, changeable between `refreshActivity()` calls.
    private final class StateBox {
        var forAll: FocusActivityState = .none
        var perTag: [String: FocusActivityState] = [:]
        func state(_ tag: String) -> FocusActivityState { perTag[tag] ?? forAll }
    }

    private final class CountingRequester: SessionListRequesting {
        private(set) var requests = 0
        func requestSessionList() { requests += 1 }
    }

    private struct Sidebar {
        let tabBar: TabBarView
        let window: NSWindow
    }

    private struct Shot {
        let frame: NSRect
        let label: NSRect
        let secondary: NSRect?
        let blocking: NSRect?
        let waiting: NSRect?
        let ownPill: NSRect?
        let attentionDot: NSRect?
        let slot: NSRect
    }

    private static let e2eWindowID = 9_000_011

    private var box = StateBox()
    private var originalRefresher: SessionListRefresher!
    private var e2eTag: String?
    private var originalCoordinator: FocusActivityCoordinator!
    private var e2eSuite: String!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        box = StateBox()
        // The end-to-end test reports a visible window to the shared store: keep any request it causes off the daemon.
        originalRefresher = AppStore.shared.sessionListRefresher
        AppStore.shared.sessionListRefresher = SessionListRefresher(requester: CountingRequester(), schedule: { _, _, _ in {} })
        // A private defaults suite: the standard domain is never touched.
        e2eSuite = "test.fa-row.\(UUID())"
        let defaults = UserDefaults(suiteName: e2eSuite)!
        defaults.removePersistentDomain(forName: e2eSuite)
        originalCoordinator = AppStore.shared.focusActivity
        AppStore.shared.installFocusActivityForTesting(FocusActivityCoordinator(store: FocusSeenStore(defaults: defaults)))
        addTeardownBlock { [suite = self.e2eSuite!] in
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            UserDefaults.standard.removeSuite(named: suite)
        }
    }

    override func tearDown() {
        AppStore.shared.focusActivity.reportWindow(id: Self.e2eWindowID, sighting: nil)
        e2eTag = nil
        AppStore.shared.installFocusActivityForTesting(originalCoordinator)
        originalCoordinator = nil
        AppStore.shared.sessionListRefresher = originalRefresher
        originalRefresher = nil
        super.tearDown()
    }

    // MARK: Rig

    private func makeFocuses() -> [Focus] {
        func dynamic(_ id: String, _ agent: String, _ repo: String, org: String) -> Focus {
            Focus(id: id, agentTag: agent, projectPath: "/tmp/fa-row-nonexistent/\(repo)", isBuiltIn: false, org: org, sessionSummary: nil)
        }
        return Focus.builtIns + [
            dynamic("farow-1", "claudia", "admin-portal", org: "Carefeed"),
            dynamic("farow-2", "cody",    "admin-portal", org: "Carefeed"),
            dynamic("farow-3", "claudia", "nostromo",     org: "Carefeed"),
            dynamic("farow-4", "cody",    "acme-web",     org: "Acme"),
            dynamic("farow-5", "redd",    "acme-web",     org: "Acme"),
        ]
    }

    private func makeSidebar(width: CGFloat = Theme.sidebarWidth, focuses: [Focus]? = nil,
                             usingTestProvider: Bool = true) -> Sidebar {
        let size = NSSize(width: width, height: 900)
        let tabBar = TabBarView(frame: NSRect(origin: .zero, size: size))
        tabBar.autoresizingMask = [.width, .height]
        let window = FixedWindow(contentRect: NSRect(origin: NSPoint(x: 60, y: 60), size: size),
                                 styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = tabBar
        window.alphaValue = 0
        window.orderFront(nil)
        addTeardownBlock {
            window.orderOut(nil)
            window.contentView = nil
        }
        if usingTestProvider {
            let box = self.box
            tabBar.activityStateProvider = { box.state($0) }
        }
        tabBar.setFocuses(focuses ?? makeFocuses())
        settle(window)
        return Sidebar(tabBar: tabBar, window: window)
    }

    private func settle(_ window: NSWindow, turns: Int = 10) {
        for _ in 0 ..< turns {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
        }
    }

    @discardableResult
    private func waitUntil(timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { XCTFail("condition not met within \(timeout)s", file: file, line: line); return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return true
    }

    private func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        for sub in view.subviews { if let found = scrollView(in: sub) { return found } }
        return nil
    }

    private func documentView(_ sidebar: Sidebar) throws -> NSView {
        let scroll = try XCTUnwrap(scrollView(in: sidebar.tabBar), "the sidebar has a scroll view")
        return try XCTUnwrap(scroll.documentView, "the sidebar has a document view")
    }

    private func items(_ sidebar: Sidebar) throws -> [NavTabItem] {
        try documentView(sidebar).subviews.compactMap { $0 as? NavTabItem }
    }

    private func documentHeight(_ sidebar: Sidebar) throws -> CGFloat { try documentView(sidebar).frame.height }

    private func shot(_ item: NavTabItem) -> Shot {
        Shot(frame: item.frame, label: item.labelFrame, secondary: item.secondaryFrame, blocking: item.blockingPillFrame,
             waiting: item.waitingPillFrame, ownPill: item.pillFrame, attentionDot: item.attentionDotFrame,
             slot: item.activitySlotFrame)
    }

    private func assertSameShot(_ a: Shot, _ b: Shot, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        assertSameRect(a.frame, b.frame, "row frame (height!): \(context)", file: file, line: line)
        assertSameRect(a.label, b.label, "name: \(context)", file: file, line: line)
        assertSameOptionalRect(a.secondary, b.secondary, "second line: \(context)", file: file, line: line)
        assertSameOptionalRect(a.blocking, b.blocking, "blocking pill: \(context)", file: file, line: line)
        assertSameOptionalRect(a.waiting, b.waiting, "waiting pill: \(context)", file: file, line: line)
        assertSameOptionalRect(a.ownPill, b.ownPill, "own pill: \(context)", file: file, line: line)
        assertSameOptionalRect(a.attentionDot, b.attentionDot, "attention dot: \(context)", file: file, line: line)
        assertSameRect(a.slot, b.slot, "slot: \(context)", file: file, line: line)
    }

    private struct Decoration {
        let name: String
        let environments: [String]
        let attention: Bool
        let pills: Bool
    }

    private let decorations: [Decoration] = [
        Decoration(name: "plain", environments: [], attention: false, pills: false),
        Decoration(name: "pills", environments: [], attention: false, pills: true),
        Decoration(name: "environment tag and attention dot", environments: ["production"], attention: true, pills: false),
        Decoration(name: "everything", environments: ["production"], attention: true, pills: true),
    ]

    private func decorate(_ sidebar: Sidebar, _ d: Decoration) throws {
        for item in try items(sidebar) {
            item.environments = d.environments
            item.needsAttention = d.attention
            if d.pills {
                if item.focus.isBuiltIn {
                    item.setBadge(FocusBadge(pill: "12", level: .needsYouNow, accessibilityLabel: "\(item.focus.agentTag), 12",
                                             blocking: 2, waiting: 7))
                } else {
                    item.setBadge(FocusBadge.needsYou(blocking: 2, waiting: 7))
                }
            } else {
                item.setBadge(nil)
            }
        }
        settle(sidebar.window, turns: 4)
    }

    private func flip(_ sidebar: Sidebar, to state: FocusActivityState) {
        box.forAll = state
        sidebar.tabBar.refreshActivity()
        settle(sidebar.window, turns: 4)
    }

    // MARK: The rig itself is not vacuous

    func testTheRowsAreRealAndLaidOutByTheAppsOwnConstraints() throws {
        let sidebar = makeSidebar()
        let rows = try items(sidebar)
        XCTAssertEqual(rows.count, Focus.builtIns.count + 5, "the built-ins and five dynamic focuses")
        for item in rows {
            XCTAssertGreaterThan(item.frame.width, Theme.sidebarWidth - 10, item.focus.id)
            XCTAssertTrue(item.frame.height == Theme.navItemSubtitleHeight || item.frame.height == Theme.navItemHeight,
                          "\(item.focus.id) is pinned to a real row height by TabBarView: \(item.frame.height)")
            XCTAssertGreaterThan(item.labelFrame.width, 10, "the name has been laid out: \(item.focus.id)")
        }
        XCTAssertGreaterThan(try documentHeight(sidebar), 8 * Theme.navItemHeight)
        let xs = Set(rows.map { $0.labelFrame.minX })
        XCTAssertTrue(xs.isSubset(of: [17, 29]), "name frames start at 17 (29 when nested under a repo header): \(xs)")
        XCTAssertTrue(xs.contains(29), "some rows are nested, so both indents are exercised")
    }

    // MARK: Nothing moves

    func testFlippingTheMarkNeverMovesAnythingInTheRealRows() throws {
        for width in [Theme.sidebarWidth, 140, 220] {
            for d in decorations {
                let sidebar = makeSidebar(width: width)
                try decorate(sidebar, d)
                let rows = try items(sidebar)
                let ids = rows.map { ObjectIdentifier($0) }
                let baseline = rows.map(shot)
                let height = try documentHeight(sidebar)
                XCTAssertGreaterThan(height, 100)

                for (label, state) in allStates {
                    flip(sidebar, to: state)
                    let now = try items(sidebar)
                    XCTAssertEqual(now.map { ObjectIdentifier($0) }, ids, "no row was rebuilt: \(label), \(d.name), \(Int(width)) pt")
                    XCTAssertEqual(try documentHeight(sidebar), height, accuracy: 0.01,
                                   "document height: \(label), \(d.name), \(Int(width)) pt")
                    for (item, before) in zip(now, baseline) {
                        assertSameShot(shot(item), before, "\(item.focus.id), \(label), \(d.name), \(Int(width)) pt")
                        XCTAssertEqual(item.activityState, state, "\(item.focus.id) was refreshed in place")
                        XCTAssertEqual(item.drawnActivityMark != nil, state != FocusActivityState.none, "\(item.focus.id), \(label)")
                    }
                }
                flip(sidebar, to: .none)
                for (item, before) in zip(try items(sidebar), baseline) {
                    assertSameShot(shot(item), before, "back to none: \(item.focus.id), \(d.name), \(Int(width)) pt")
                    XCTAssertNil(item.drawnActivityMark)
                }
            }
        }
    }

    func testRefreshActivityUpdatesRowsInPlaceWithoutRebuildingThem() throws {
        let sidebar = makeSidebar()
        let rows = try items(sidebar)
        let ids = rows.map { ObjectIdentifier($0) }
        let rebuiltBefore = RebuildCounters.snapshot["sidebarRebuilt"] ?? 0

        for (_, state) in allStates + allStates.reversed() {
            flip(sidebar, to: state)
        }
        sidebar.tabBar.refreshActivity()
        sidebar.tabBar.refreshActivity()

        XCTAssertEqual(try items(sidebar).map { ObjectIdentifier($0) }, ids, "the very same NavTabItem instances remain")
        XCTAssertEqual(RebuildCounters.snapshot["sidebarRebuilt"] ?? 0, rebuiltBefore, "the sidebar was not torn down and rebuilt")
    }

    // MARK: Geometry that a pinned-height helper cannot fake

    func testTheSlotNeverTouchesAnythingElseInARealRow() throws {
        for width in [Theme.sidebarWidth, 140] {
            for d in decorations {
                for highlighted in [false, true] {
                    let sidebar = makeSidebar(width: width)
                    try decorate(sidebar, d)
                    if highlighted {
                        // Selected rows draw two 3 pt bars at the leading edge; blocked rows add the red one.
                        sidebar.tabBar.activeFocus = try XCTUnwrap(items(sidebar).first { !$0.focus.isBuiltIn }?.focus)
                        for item in try items(sidebar) where !item.focus.isBuiltIn && !d.pills {
                            item.setBadge(FocusBadge.needsYou(blocking: 2, waiting: 0))
                        }
                        settle(sidebar.window, turns: 4)
                    }
                    for (label, state) in shownStates {
                        flip(sidebar, to: state)
                        for item in try items(sidebar) {
                            let at = "\(item.focus.id), \(label), \(d.name), highlighted \(highlighted), \(Int(width)) pt"
                            let slot = item.activitySlotFrame
                            XCTAssertEqual(item.activityMarkFrame, slot, "a shown mark is in the slot: \(at)")
                            XCTAssertTrue(item.bounds.insetBy(dx: -0.01, dy: -0.01).contains(slot), "inside the row: \(at)")
                            XCTAssertLessThan(slot.maxX, item.labelFrame.minX, "left of the name: \(at)")
                            XCTAssertEqual(slot.maxX, item.nameAlignmentFrame.minX - 4, accuracy: 0.01, "4 pt from the name: \(at)")
                            XCTAssertEqual(slot.midY, item.nameAlignmentFrame.midY, accuracy: 0.51, "centred on the name line: \(at)")
                            XCTAssertFalse(slot.intersects(item.labelFrame), "overlaps the name: \(at)")
                            if let second = item.secondaryFrame { XCTAssertFalse(slot.intersects(second), "overlaps the second line: \(at)") }
                            if let dot = item.attentionDotFrame { XCTAssertFalse(slot.intersects(dot), "overlaps the attention dot: \(at)") }
                            for pill in [item.blockingPillFrame, item.waitingPillFrame, item.pillFrame].compactMap({ $0 }) {
                                XCTAssertFalse(slot.intersects(pill), "overlaps a pill: \(at)")
                            }
                            let bars = NSRect(x: 0, y: 0, width: 6, height: item.bounds.height)
                            XCTAssertFalse(slot.intersects(bars), "overlaps the leading bars: \(at)")
                            XCTAssertGreaterThanOrEqual(slot.minX, 6, at)
                        }
                    }
                }
            }
        }
    }

    func testNoMarkMeansNoMarkFrameButTheSlotIsStillReserved() throws {
        let sidebar = makeSidebar()
        for item in try items(sidebar) {
            XCTAssertNil(item.activityMarkFrame, item.focus.id)
            XCTAssertEqual(item.activitySlotFrame.size, CGSize(width: 8, height: 8), item.focus.id)
            XCTAssertEqual(item.activitySlotFrame.maxX, item.nameAlignmentFrame.minX - 4, accuracy: 0.01, item.focus.id)
        }
    }

    // MARK: The provider

    func testRowsTakeTheirStateFromTheProviderWhenTheyAreBuiltAndByTheirSessionTag() throws {
        let focuses = makeFocuses()
        let unread = try XCTUnwrap(focuses.first { $0.id == "farow-2" })
        let problem = try XCTUnwrap(focuses.first { $0.id == "perri" })
        box.perTag = [unread.sessionTag: .unread(count: 2), problem.sessionTag: .problem(.apiError)]

        let sidebar = makeSidebar(focuses: focuses)   // provider installed before setFocuses
        for item in try items(sidebar) {
            switch item.focus.id {
            case "farow-2":
                XCTAssertEqual(item.activityState, .unread(count: 2))
                XCTAssertEqual(item.drawnActivityMark?.shape, .dot)
                XCTAssertEqual(item.activityToolTip, "2 new messages")
            case "perri":
                XCTAssertEqual(item.activityState, .problem(.apiError))
                XCTAssertEqual(item.drawnActivityMark?.shape, .warningDot)
            default:
                XCTAssertEqual(item.activityState, FocusActivityState.none, item.focus.id)
                XCTAssertNil(item.drawnActivityMark, item.focus.id)
            }
        }

        // Change one focus's answer and refresh: only that row changes.
        box.perTag[unread.sessionTag] = .activity
        sidebar.tabBar.refreshActivity()
        for item in try items(sidebar) where item.focus.id == "farow-2" {
            XCTAssertEqual(item.activityState, .activity)
            XCTAssertEqual(item.drawnActivityMark?.shape, .ring)
        }
        for item in try items(sidebar) where item.focus.id == "perri" {
            XCTAssertEqual(item.activityState, .problem(.apiError))
        }
    }

    func testARowRebuiltBySetFocusesShowsTheProvidersStateStraightAway() throws {
        let sidebar = makeSidebar()
        box.forAll = .unread(count: 3)
        sidebar.tabBar.refreshActivity()
        var focuses = makeFocuses()
        focuses.append(Focus(id: "farow-6", agentTag: "cody", projectPath: "/tmp/fa-row-nonexistent/zeta", isBuiltIn: false,
                             org: "Zeta", sessionSummary: nil))
        sidebar.tabBar.setFocuses(focuses)
        settle(sidebar.window)
        let rows = try items(sidebar)
        XCTAssertEqual(rows.count, 11)
        for item in rows {
            XCTAssertEqual(item.activityState, .unread(count: 3), "\(item.focus.id): rebuilt rows start from the provider, not from none")
        }
    }

    // MARK: Through the shared store (the default provider)

    func testTheDefaultProviderFollowsTheSharedStoresCoordinatorAndClearsWhenTheFocusIsSeen() throws {
        let focus = Focus(id: "farow-e2e-\(UUID().uuidString.prefix(8))", agentTag: "cody", projectPath: "/tmp/fa-row-nonexistent/e2e",
                          isBuiltIn: false, org: "Carefeed", sessionSummary: nil)
        let tag = focus.sessionTag
        e2eTag = tag
        let sidebar = makeSidebar(focuses: [focus], usingTestProvider: false)
        func row() throws -> NavTabItem { try XCTUnwrap(try items(sidebar).first { $0.focus.id == focus.id }) }
        func counters(_ t: UInt64, _ m: UInt64) -> FocusActivityCounters {
            FocusActivityCounters(epoch: "e2e", turns: t, messages: m, problems: 0)
        }
        func ingest(_ c: FocusActivityCounters) {
            AppStore.shared.applyForTesting(.sessionListResp([SessionActivityEntry(tag: tag, activity: c)]))
        }

        ingest(counters(5, 3))
        waitUntil { self.settle(sidebar.window, turns: 1); return true }
        XCTAssertEqual(try row().activityState, FocusActivityState.none, "first sight baselines: no mark")

        ingest(counters(7, 5))
        waitUntil { self.settle(sidebar.window, turns: 1); return (try? row().activityState) == .unread(count: 2) }
        XCTAssertEqual(try row().drawnActivityMark?.shape, .dot, "the row follows the coordinator's change")
        XCTAssertEqual(try row().activityToolTip, "2 new messages")

        AppStore.shared.focusActivity.reportWindow(
            id: Self.e2eWindowID, sighting: FocusWindowSighting(tag: tag, isKey: true, isVisible: true))
        waitUntil { self.settle(sidebar.window, turns: 1); return (try? row().activityState) == FocusActivityState.none }
        XCTAssertNil(try row().drawnActivityMark, "looking at the focus clears its mark")

        ingest(counters(9, 7))
        settle(sidebar.window, turns: 3)
        XCTAssertEqual(try row().activityState, FocusActivityState.none, "arrivals while it is seen never flag")

        AppStore.shared.focusActivity.reportWindow(id: Self.e2eWindowID, sighting: nil)
        ingest(counters(9, 7))      // the refresh that leaving asks for: what was watched stays unflagged
        ingest(counters(10, 7))
        waitUntil { self.settle(sidebar.window, turns: 1); return (try? row().activityState) == .activity }
        XCTAssertEqual(try row().drawnActivityMark?.shape, .ring)
    }
}

// MARK: - Colours and contrast

final class FocusActivityColorTests: XCTestCase {

    private static let nonText = 3.0

    func testTheThreeColoursAreExactlyTheSpecifiedOnes() throws {
        let mark = try rgba(Theme.focusMark), problem = try rgba(Theme.focusMarkProblem), glyph = try rgba(Theme.focusMarkGlyph)
        XCTAssertEqual(mark.r, 130 / 255, accuracy: 0.003)
        XCTAssertEqual(mark.g, 150 / 255, accuracy: 0.003)
        XCTAssertEqual(mark.b, 190 / 255, accuracy: 0.003)
        XCTAssertEqual(mark.a, 1, accuracy: 0.001)
        XCTAssertEqual(problem.r, 204 / 255, accuracy: 0.003)
        XCTAssertEqual(problem.g, 150 / 255, accuracy: 0.003)
        XCTAssertEqual(problem.b, 80 / 255, accuracy: 0.003)
        XCTAssertEqual(problem.a, 1, accuracy: 0.001)
        let bg = try rgba(Theme.bg)
        XCTAssertEqual(glyph.r, bg.r, accuracy: 0.003)
        XCTAssertEqual(glyph.g, bg.g, accuracy: 0.003)
        XCTAssertEqual(glyph.b, bg.b, accuracy: 0.003)
    }

    func testTheMarkColoursAreNotAnyOfTheColoursTheRowAlreadyUses() throws {
        let taken: [(String, NSColor)] = [
            ("blocking red", Theme.needsYouNow), ("amber", Theme.amber), ("waiting pill text", Theme.waitingPillText),
            ("purple decision dot", Theme.attention), ("cornflower", Theme.cornflower),
        ]
        for (mineName, mine) in [("focusMark", Theme.focusMark), ("focusMarkProblem", Theme.focusMarkProblem)] {
            let m = try rgba(mine)
            for (name, other) in taken {
                let o = try rgba(other)
                let distance = abs(m.r - o.r) + abs(m.g - o.g) + abs(m.b - o.b)
                XCTAssertGreaterThan(distance, 0.15, "\(mineName) must not read as \(name)")
            }
        }
        let a = try rgba(Theme.focusMark), b = try rgba(Theme.focusMarkProblem)
        XCTAssertGreaterThan(abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b), 0.3, "a problem is not the quiet mark's colour")
    }

    private func nonTextRatios() throws -> [String: Double] {
        let bar = Theme.bgBar
        let backdrops: [(String, NSColor)] = [
            ("the bar", bar),
            ("the active row", try over(Theme.cornflower.withAlphaComponent(0.12), bar)),
            ("the blocking row (also active and blocking)", try over(Theme.blockingRowFill, bar)),
        ]
        var result: [String: Double] = [:]
        for (name, backdrop) in backdrops {
            result["mark on \(name)"] = try contrast(Theme.focusMark, backdrop)
            result["problem dot on \(name)"] = try contrast(Theme.focusMarkProblem, backdrop)
        }
        result["glyph on the problem dot"] = try contrast(Theme.focusMarkGlyph, Theme.focusMarkProblem)
        return result
    }

    func testTheMarkMeetsThreeToOneOnEveryRowBackdropInBothAppearances() throws {
        var perAppearance: [NSAppearance.Name: [String: Double]] = [:]
        for name in appearances {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            var computed: [String: Double] = [:]
            var failure: Error?
            appearance.performAsCurrentDrawingAppearance {
                do { computed = try nonTextRatios() } catch { failure = error }
            }
            if let failure { throw failure }
            XCTAssertEqual(computed.count, 7)
            for (pair, ratio) in computed {
                XCTAssertGreaterThanOrEqual(ratio, Self.nonText, "\(pair) under \(name.rawValue): \(ratio)")
            }
            perAppearance[name] = computed
        }
        let light = try XCTUnwrap(perAppearance[.aqua]), dark = try XCTUnwrap(perAppearance[.darkAqua])
        for (pair, ratio) in light {
            XCTAssertEqual(ratio, try XCTUnwrap(dark[pair]), accuracy: 1e-9, "\(pair) differs between appearances")
        }
    }
}
