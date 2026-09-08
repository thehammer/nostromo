import XCTest
import AppKit

// TabRegionView.swift is compiled into this target directly (logic test —
// no host app, no @testable import), same convention as TurnInteractionTests.
//
// The serious defect these guard: `stripStack` (an NSStackView) defaults to
// `.centerY` cross-axis alignment, so each `TabButtonView` is sized to its
// own fitting height rather than stretched to fill the strip. With no height
// constraint on `TabButtonView` and nothing anchored to its own bottom, that
// fitting height is 0 — which makes its `clickButton` (pinned top+bottom to
// the button) 0pt tall too. A 0pt-tall button can never be hit by `hitTest`,
// so a click on a visible, correctly-labeled tab silently does nothing.
// Meanwhile the label/caption text fields still draw (AppKit doesn't clip by
// default), bleeding out past the 0pt button into the content pane below.
//
// `TabButtonView` is `private` to TabRegionView.swift, so nothing here can
// name it or cast to it — every assertion below is expressed purely against
// `NSView`/`NSButton`/`NSTextField`/`NSStackView`, found generically by
// walking the real view hierarchy. That is the membrane these tests enforce:
// what an operator's click and AppKit's own geometry say, not TabButtonView's
// private layout.

// MARK: - Shared view-hierarchy helpers

/// Depth-first search for the first descendant of `type` under `view`,
/// including `view`'s own subviews but not `view` itself.
private func firstDescendant<T>(of type: T.Type, in view: NSView) -> T? {
    for sub in view.subviews {
        if let match = sub as? T { return match }
        if let found = firstDescendant(of: type, in: sub) { return found }
    }
    return nil
}

/// Every descendant of `type` under `view`, depth-first, `view` itself excluded.
private func allDescendants<T>(of type: T.Type, in view: NSView) -> [T] {
    var results: [T] = []
    for sub in view.subviews {
        if let match = sub as? T { results.append(match) }
        results.append(contentsOf: allDescendants(of: type, in: sub))
    }
    return results
}

/// Is `view` equal to, or nested somewhere under, `ancestor`?
private func isView(_ view: NSView, containedIn ancestor: NSView) -> Bool {
    var current: NSView? = view
    while let c = current {
        if c === ancestor { return true }
        current = c.superview
    }
    return false
}

/// `TabRegionView` builds exactly one `NSStackView` for its tab strip
/// (`stripStack`, private to the file). Found generically since the field
/// itself isn't visible here.
private func stripStack(in region: TabRegionView) throws -> NSStackView {
    try XCTUnwrap(firstDescendant(of: NSStackView.self, in: region),
                 "TabRegionView must lay out its tab strip via an NSStackView")
}

/// Build a `TabRegionView` with two tabs and a realistic detail-region frame
/// (mirrors the geometry in the bug report), then force a real Auto Layout
/// pass. `TabRegionView` does not require an `NSWindow` to run Auto Layout,
/// and — because it's given no superview here — its own bounds coordinate
/// system is what `hitTest` calls below are made in.
private func makeTabRegion(
    frame: NSRect = NSRect(x: 0, y: 0, width: 880, height: 481),
    activePaneId: String = "conversation"
) -> TabRegionView {
    let tabs = [
        TabRegionView.Tab(paneId: "conversation", label: "Conversation", view: NSView()),
        TabRegionView.Tab(paneId: "diff", label: "Diff", view: NSView()),
    ]
    let region = TabRegionView(tabs: tabs, activePaneId: activePaneId)
    region.frame = frame
    region.layoutSubtreeIfNeeded()
    return region
}

// MARK: - TabRegionViewHitAreaTests

/// The core regression: a tab's click target must actually occupy real,
/// hittable screen space. Before the fix, `stripStack`'s default `.centerY`
/// alignment plus no height constraint on `TabButtonView` collapses every
/// tab button — and its `clickButton` — to zero height, so a click at a
/// tab's visible center hits nothing.
final class TabRegionViewHitAreaTests: XCTestCase {

    func testEveryTabsClickButtonHasNonZeroHeightAfterLayout() throws {
        let region = makeTabRegion()
        let stack = try stripStack(in: region)
        XCTAssertEqual(stack.arrangedSubviews.count, 2, "one arranged subview per tab")

        for (index, tabView) in stack.arrangedSubviews.enumerated() {
            let clickButton = try XCTUnwrap(
                firstDescendant(of: NSButton.self, in: tabView),
                "tab \(index) must contain a clickable NSButton"
            )
            XCTAssertGreaterThan(
                clickButton.frame.height, 0,
                "tab \(index)'s click target has zero height after layout — it can never " +
                "receive a click, because hitTest at its visual center will always return nil"
            )
        }
    }

    func testClickingEachTabsVisualCenterHitsThatTabAndNoOtherTab() throws {
        let region = makeTabRegion()
        let stack = try stripStack(in: region)

        for (index, tabView) in stack.arrangedSubviews.enumerated() {
            let center = NSPoint(x: tabView.bounds.midX, y: tabView.bounds.midY)
            let pointInRegion = tabView.convert(center, to: region)

            let hit = try XCTUnwrap(
                region.hitTest(pointInRegion),
                "hitTest at tab \(index)'s visual center (\(pointInRegion)) returned nil — " +
                "an operator clicking dead-center on a visible tab hits nothing"
            )
            XCTAssertTrue(
                isView(hit, containedIn: tabView),
                "hitTest at tab \(index)'s visual center landed on a view outside that tab's " +
                "own button (got \(hit)) — the wrong tab (or nothing useful) would receive the click"
            )
        }
    }

    /// Belt-and-suspenders: the *programmatic* selection path is expected to
    /// already work on unfixed code (it doesn't go through hitTest at all).
    /// This is not, by itself, proof that a real click on the strip works —
    /// the two tests above are what must fail pre-fix.
    func testClickingATabsButtonMakesItTheActivePane() throws {
        let region = makeTabRegion(activePaneId: "conversation")
        let stack = try stripStack(in: region)
        let diffTabView = stack.arrangedSubviews[1]
        let clickButton = try XCTUnwrap(firstDescendant(of: NSButton.self, in: diffTabView))

        clickButton.performClick(nil)

        XCTAssertEqual(
            region.activePaneId, "diff",
            "performClick on tab 1's button must select that tab"
        )
    }
}

// MARK: - TabRegionViewCaptionGeometryTests

/// The second half of the regression: with no height on `TabButtonView`,
/// `labelField`/`captionField` still draw (AppKit doesn't clip by default)
/// below/outside the 0pt-tall button, overlapping the content pane beneath
/// the strip. Separately, the strip's overall height must not depend on
/// whether any tab happens to be showing a caption.
final class TabRegionViewCaptionGeometryTests: XCTestCase {

    func testCaptionRendersFullyWithinItsOwningTabButtonsBounds() throws {
        let region = makeTabRegion()
        region.setCaption("waiting on you", for: "conversation")
        region.layoutSubtreeIfNeeded()

        let stack = try stripStack(in: region)
        let conversationTabView = stack.arrangedSubviews[0]

        let captionField = try XCTUnwrap(
            allDescendants(of: NSTextField.self, in: conversationTabView)
                .first { $0.stringValue == "waiting on you" },
            "expected a caption NSTextField carrying the text passed to setCaption(_:for:)"
        )

        XCTAssertGreaterThanOrEqual(
            captionField.frame.minY, 0,
            "the caption draws below its own tab button's bottom edge — it overlaps the " +
            "content pane beneath the strip, the exact defect this guards against"
        )
        XCTAssertLessThanOrEqual(
            captionField.frame.maxY, conversationTabView.bounds.height,
            "the caption draws above its own tab button's top edge"
        )
    }

    func testTabStripHeightIsUnaffectedByWhetherACaptionIsShowing() throws {
        let withoutCaption = makeTabRegion()

        let withCaption = makeTabRegion()
        withCaption.setCaption("some reason", for: "conversation")
        withCaption.layoutSubtreeIfNeeded()

        let stackWithout = try stripStack(in: withoutCaption)
        let stackWith = try stripStack(in: withCaption)

        XCTAssertEqual(
            stackWithout.frame.height, stackWith.frame.height,
            "the tab strip must not grow or shrink depending on whether a caption is " +
            "showing, or the whole detail region reflows underneath it when one appears/clears"
        )
    }
}
