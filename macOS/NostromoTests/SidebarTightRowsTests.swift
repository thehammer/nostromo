import XCTest
import AppKit
import NostromoKit

// Sidebar rows are one height (40 pt) and the "needs you" counts have room to breathe.
//
//   * Every focus row, built-in or not, is 40 pt tall in every state: no mark, each activity mark, each
//     pill, both pills. Nothing about a row's state changes its height or where its name sits.
//   * A full count pill is as wide for 1 as for 99+, so a count going from 9 to 10 never resizes it; it
//     ends 12 pt from the row's right edge and keeps 8 pt of padding either side of its glyph and count.
//   * The highlight bars span the whole row, and the activity mark and attention dot sit on the title line.
//
// Rows here are the real ones: built by `TabBarView` (through `buildNavRows`) and laid out by its own
// constraints, so the height is whatever the app really pins, never a number the test supplies.

final class SidebarTightRowsTests: XCTestCase {

    /// Literal on purpose: these are the product's numbers, so a change to the constants must fail here.
    private let rowHeight: CGFloat = 40
    private let requiredTrailingInset: CGFloat = 12

    // MARK: Rig

    private func dynamicFocuses() -> [Focus] {
        [
            Focus(id: "11111111-aaaa", agentTag: "cody", projectPath: "/tmp/tight-rows-nonexistent/nostromo",
                  isBuiltIn: false, org: "Carefeed", sessionSummary: "Wiring the sidebar"),
            Focus(id: "22222222-bbbb", agentTag: "cody", projectPath: nil, isBuiltIn: false, org: "Carefeed"),
            Focus(id: "33333333-cccc", agentTag: "redd", projectPath: "/tmp/tight-rows-nonexistent/admin-portal",
                  isBuiltIn: false, org: "Carefeed"),
        ]
    }

    /// A real `TabBarView` in an off-screen window, at `width` (the rows are one point narrower: the
    /// sidebar's right border).
    private func makeSidebar(width: CGFloat = Theme.sidebarWidth, focuses: [Focus]) -> (tabBar: TabBarView, rows: [NavTabItem]) {
        _ = NSApplication.shared
        let tabBar = TabBarView(frame: NSRect(x: 0, y: 0, width: width, height: 900))
        tabBar.activityStateProvider = { _ in .none }
        let window = NSWindow(contentRect: tabBar.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        window.contentView = tabBar
        addTeardownBlock { window.close() }
        tabBar.setFocuses(focuses)
        tabBar.layoutSubtreeIfNeeded()
        let rows = navItems(in: tabBar)
        XCTAssertEqual(rows.count, focuses.count, "one row per focus")
        return (tabBar, rows)
    }

    private func navItems(in v: NSView) -> [NavTabItem] {
        v.subviews.flatMap { ($0 as? NavTabItem).map { [$0] } ?? [] } + v.subviews.flatMap(navItems(in:))
    }

    private func relayout(_ tabBar: TabBarView) { tabBar.layoutSubtreeIfNeeded() }

    private func counts(_ blocking: Int, _ waiting: Int) -> FocusBadge? {
        blocking == 0 && waiting == 0 ? nil : FocusBadge.needsYou(blocking: blocking, waiting: waiting)
    }

    private struct State {
        let name: String
        let activity: FocusActivityState
        let blocking: Int
        let waiting: Int
        var attention = false
    }

    private let states: [State] = [
        State(name: "none", activity: .none, blocking: 0, waiting: 0),
        State(name: "activity ring", activity: .activity, blocking: 0, waiting: 0),
        State(name: "unread dot", activity: .unread(count: 3), blocking: 0, waiting: 0),
        State(name: "problem mark", activity: .problem(nil), blocking: 0, waiting: 0),
        State(name: "blocking pill", activity: .none, blocking: 2, waiting: 0),
        State(name: "waiting pill", activity: .none, blocking: 0, waiting: 7),
        State(name: "both pills", activity: .none, blocking: 2, waiting: 7),
        State(name: "both pills, three digits", activity: .none, blocking: 150, waiting: 150),
        State(name: "everything", activity: .problem(nil), blocking: 2, waiting: 7, attention: true),
    ]

    private func show(_ s: State, on item: NavTabItem) {
        item.setBadge(counts(s.blocking, s.waiting))
        item.setActivity(s.activity)
        item.needsAttention = s.attention
    }

    // MARK: 1. Height

    func testTheConstantsSayEveryRowIsFortyPoints() {
        XCTAssertEqual(Theme.navItemHeight, rowHeight)
        XCTAssertEqual(Theme.navItemSubtitleHeight, rowHeight, "a row with a second line is no taller than one without")
    }

    func testEveryFocusRowIsFortyPointsHighInEveryStateAndTheSameAcrossStates() {
        for width in [Theme.sidebarWidth, 120] {
            let (tabBar, rows) = makeSidebar(width: width, focuses: Focus.builtIns + dynamicFocuses())
            XCTAssertGreaterThan(rows.count, 3, "built-ins and dynamic focuses are both exercised")
            for item in rows {
                XCTAssertEqual(item.frame.height, rowHeight, "\(item.focus.id) at rest, \(Int(width)) pt")
            }
            for s in states {
                for item in rows { show(s, on: item) }
                relayout(tabBar)
                for item in rows {
                    let at = "\(item.focus.id), \(s.name), \(Int(width)) pt"
                    XCTAssertEqual(item.frame.height, rowHeight, at)
                    XCTAssertEqual(item.bounds.height, rowHeight, at)
                }
            }
            // And back to nothing.
            for item in rows { show(State(name: "none", activity: .none, blocking: 0, waiting: 0), on: item) }
            relayout(tabBar)
            for item in rows { XCTAssertEqual(item.frame.height, rowHeight, "back to none: \(item.focus.id)") }
        }
    }

    // MARK: 2. The name does not move

    func testTheNameLabelIsInTheSameFrameInEveryState() {
        for width in [Theme.sidebarWidth, 120] {
            let (tabBar, rows) = makeSidebar(width: width, focuses: Focus.builtIns + dynamicFocuses())
            let baseline = rows.map { $0.labelFrame }
            for s in states {
                for item in rows { show(s, on: item) }
                relayout(tabBar)
                for (item, before) in zip(rows, baseline) {
                    // The name's position and height never change; its width may follow the attention dot (as before).
                    XCTAssertEqual(item.labelFrame.origin, before.origin, "name origin: \(item.focus.id), \(s.name), \(Int(width)) pt")
                    XCTAssertEqual(item.labelFrame.height, before.height, "name height: \(item.focus.id), \(s.name), \(Int(width)) pt")
                }
            }
        }
    }

    // MARK: 3. The pills fit, 12 pt from the right edge

    private static let sampleCounts = [1, 9, 10, 99, 100]

    func testThePillTrailingInsetIsTwelvePoints() {
        XCTAssertEqual(NavTabItem.pillTrailing, requiredTrailingInset)
    }

    func testPillsAreInsideTheRowAndEndAtLeastTwelvePointsFromTheRightEdge() throws {
        // The sidebar's own width, a middle one, and 61, which gives a 60 pt row (the sidebar's right border
        // takes a point): the narrowest the pill tests use. Everything is measured against the row's own width.
        for tabBarWidth in [Theme.sidebarWidth, 121, 61] {
            let (tabBar, rows) = makeSidebar(width: tabBarWidth, focuses: dynamicFocuses())
            for item in rows {
                let leading = item.labelFrame.minX + 2   // where the second line starts (the field's 2 pt padding)
                for count in Self.sampleCounts {
                    for kind in ["blocking", "waiting"] {
                        item.setBadge(kind == "blocking" ? counts(count, 0) : counts(0, count))
                        relayout(tabBar)
                        let at = "\(kind) \(count), \(item.focus.id), row \(Int(item.bounds.width)) pt"
                        XCTAssertEqual(kind == "blocking" ? item.blockingPillText : item.waitingPillText,
                                       count > 99 ? "99+" : "\(count)", at)
                        let rowWidth = item.bounds.width   // after the relayout: the row's real width
                        let pill = try XCTUnwrap(kind == "blocking" ? item.blockingPillFrame : item.waitingPillFrame, at)
                        // The blocking pill is never squeezed, so it is always whole, inside the row, with the inset.
                        // The waiting pill is too wherever it physically fits; in a row too narrow even for its
                        // collapsed form it is cut off at the slot's edge instead, so only then is it exempt.
                        guard kind == "blocking" || pill.width <= rowWidth - requiredTrailingInset - leading else { continue }
                        XCTAssertGreaterThanOrEqual(pill.minX, -0.5, "inside the row on the left: \(at)")
                        XCTAssertGreaterThanOrEqual(pill.minY, -0.5, "inside the row at the bottom: \(at)")
                        XCTAssertLessThanOrEqual(pill.maxY, item.bounds.height + 0.5, "inside the row at the top: \(at)")
                        XCTAssertLessThanOrEqual(pill.maxX, rowWidth - requiredTrailingInset + 0.5,
                                                 "ends at least 12 pt from the right edge: \(at)")
                    }
                }
                item.setBadge(nil)
                relayout(tabBar)
            }
        }
    }

    func testBothPillsTogetherStayInsideTheRowAtTheSidebarWidthWithTheInset() throws {
        let (tabBar, rows) = makeSidebar(focuses: dynamicFocuses())
        for item in rows {
            for count in Self.sampleCounts {
                item.setBadge(counts(count, count))
                relayout(tabBar)
                let at = "both \(count), \(item.focus.id)"
                let blocking = try XCTUnwrap(item.blockingPillFrame, at), waiting = try XCTUnwrap(item.waitingPillFrame, at)
                XCTAssertLessThan(blocking.maxX, waiting.minX, "side by side, not overlapping: \(at)")
                XCTAssertGreaterThanOrEqual(blocking.minX, 0, at)
                XCTAssertLessThanOrEqual(waiting.maxX, item.bounds.width - requiredTrailingInset + 0.5, at)
                XCTAssertGreaterThanOrEqual(waiting.maxX, item.bounds.width - requiredTrailingInset - 8, "and hugs that edge: \(at)")
            }
        }
    }

    // MARK: 4. A pill's width does not depend on its count

    private func pillWidth(_ kind: String, count: Int, on item: NavTabItem, in tabBar: TabBarView) throws -> CGFloat {
        item.setBadge(kind == "blocking" ? counts(count, 0) : counts(0, count))
        relayout(tabBar)
        let frame = try XCTUnwrap(kind == "blocking" ? item.blockingPillFrame : item.waitingPillFrame, "\(kind) \(count)")
        return frame.width
    }

    func testAPillIsExactlyAsWideAtTenAsAtNine() throws {
        let (tabBar, rows) = makeSidebar(focuses: dynamicFocuses())
        for item in rows {
            for kind in ["blocking", "waiting"] {
                let nine = try pillWidth(kind, count: 9, on: item, in: tabBar)
                let ten = try pillWidth(kind, count: 10, on: item, in: tabBar)
                XCTAssertEqual(ten, nine, accuracy: 0.01, "\(kind) pill, \(item.focus.id): 9 -> 10 does not resize it")
            }
        }
    }

    func testEveryFullPillIsAsWideAsAnNinetyNinePlusPill() throws {
        let (tabBar, rows) = makeSidebar(focuses: dynamicFocuses())
        for item in rows {
            for kind in ["blocking", "waiting"] {
                let widest = try pillWidth(kind, count: 100, on: item, in: tabBar)
                XCTAssertEqual(item.blockingPillText ?? item.waitingPillText, "99+")
                for count in [1, 9, 10, 99] {
                    let width = try pillWidth(kind, count: count, on: item, in: tabBar)
                    XCTAssertEqual(width, widest, accuracy: 0.01, "\(kind) \(count) is as wide as 99+, \(item.focus.id)")
                }
            }
        }
    }

    func testAPillKeepsEightPointsOfPaddingEitherSideOfItsGlyphAndCount() throws {
        // The glyph is 10 pt wide with a 2 pt gap before the count; the 99+ pill is the widest, so it is
        // the one whose size is its content plus the padding, with no minimum width helping it.
        let font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        let countWidth = ceil(("99+" as NSString).size(withAttributes: [.font: font]).width)
        let content: CGFloat = 10 + 2 + countWidth
        let (tabBar, rows) = makeSidebar(focuses: dynamicFocuses())
        for item in rows {
            for kind in ["blocking", "waiting"] {
                let width = try pillWidth(kind, count: 100, on: item, in: tabBar)
                XCTAssertGreaterThanOrEqual(width, content + 16 - 0.5, "\(kind) pill is padded 8 pt each side: \(width) vs content \(content)")
            }
        }
    }

    // MARK: 5. The highlight bars span the whole row

    private func barViews(of item: NavTabItem) -> [NSView?] {
        // The bars are the 3 pt wide subviews at x = 0 and x = 3 (see `NavRowHighlight`).
        (0 ..< 2).map { index in
            item.subviews.first { $0.frame.width == 3 && abs($0.frame.minX - CGFloat(index) * 3) < 0.01 }
        }
    }

    func testTheHighlightBarsSpanTheFullRowHeight() throws {
        let (tabBar, rows) = makeSidebar(focuses: dynamicFocuses())
        let cases: [(name: String, active: Bool, blocking: Int, visibleBars: Int)] = [
            ("blocking", false, 2, 1), ("active", true, 0, 1), ("active and blocking", true, 2, 2),
        ]
        for item in rows {
            for c in cases {
                item.isActive = c.active
                item.setBadge(counts(c.blocking, 0))
                relayout(tabBar)
                let at = "\(c.name), \(item.focus.id)"
                let shown = item.drawnBars.enumerated().filter { !$0.element.isHidden }.map { $0.offset }
                XCTAssertEqual(shown.count, c.visibleBars, "bars shown: \(at)")
                let views = barViews(of: item)
                for index in shown {
                    let bar = try XCTUnwrap(views[index], "bar \(index) is a 3 pt wide view at x = \(index * 3): \(at)")
                    XCTAssertEqual(bar.frame.minY, 0, accuracy: 0.01, "bar \(index) starts at the row's bottom: \(at)")
                    XCTAssertEqual(bar.frame.height, rowHeight, accuracy: 0.01, "bar \(index) spans the full 40 pt: \(at)")
                    XCTAssertEqual(bar.frame.height, item.bounds.height, accuracy: 0.01, "and the whole row: \(at)")
                }
            }
            item.isActive = false
            item.setBadge(nil)
        }
    }

    // MARK: 6. The marks sit on the title line

    func testTheActivityMarkIsCentredOnTheTitleLineInEveryState() {
        for width in [Theme.sidebarWidth, 120] {
            let (tabBar, rows) = makeSidebar(width: width, focuses: Focus.builtIns + dynamicFocuses())
            for s in states {
                for item in rows { show(s, on: item) }
                relayout(tabBar)
                for item in rows {
                    XCTAssertEqual(item.activitySlotFrame.midY, item.labelFrame.midY, accuracy: 0.51,
                                   "mark on the title line: \(item.focus.id), \(s.name), \(Int(width)) pt")
                    XCTAssertGreaterThanOrEqual(item.activitySlotFrame.minY, 0)
                    XCTAssertLessThanOrEqual(item.activitySlotFrame.maxY, item.bounds.height)
                }
            }
        }
    }

    func testTheAttentionDotAndTheRowsOwnPillAreCentredOnTheTitleLine() throws {
        let (tabBar, rows) = makeSidebar(focuses: Focus.builtIns + dynamicFocuses())
        for item in rows {
            item.needsAttention = true
            item.setBadge(FocusBadge(pill: "12", level: .attention, accessibilityLabel: "\(item.focus.agentTag), 12"))
            relayout(tabBar)
            let dot = try XCTUnwrap(item.attentionDotFrame, "dot shows: \(item.focus.id)")
            let pill = try XCTUnwrap(item.pillFrame, "pill shows: \(item.focus.id)")
            XCTAssertEqual(dot.midY, item.labelFrame.midY, accuracy: 0.51, "attention dot on the title line: \(item.focus.id)")
            XCTAssertEqual(pill.midY, item.labelFrame.midY, accuracy: 0.51, "own pill on the title line: \(item.focus.id)")
            XCTAssertGreaterThanOrEqual(dot.minY, 0)
            XCTAssertLessThanOrEqual(dot.maxY, item.bounds.height)
            XCTAssertGreaterThanOrEqual(pill.minY, 0)
            XCTAssertLessThanOrEqual(pill.maxY, item.bounds.height)
        }
    }
}
