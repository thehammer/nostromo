import XCTest
import AppKit

// SplitViewSwap.swift is compiled into this target directly (AppKit logic, no
// host app, same as TabRegionViewTests). These are behavioural tests of the
// bug measured live on 2026-10-06: replacing the PR detail region's
// TabRegionView with a freshly built one (a second tab joining) collapsed the
// region from half the window to ~34pt.
final class SplitViewSwapTests: XCTestCase {

    /// A side-by-side split, 1000x400, divider at the midpoint.
    private func makeHalfAndHalfSplit() -> (NSSplitView, NSView, NSView) {
        let split = NSSplitView(frame: NSRect(x: 0, y: 0, width: 1000, height: 400))
        split.isVertical = true
        split.dividerStyle = .thin
        let left = NSView(frame: .zero)
        let right = NSView(frame: .zero)
        split.addArrangedSubview(left)
        split.addArrangedSubview(right)
        split.setPosition(500, ofDividerAt: 0)
        split.adjustSubviews()
        return (split, left, right)
    }

    func testPrecondition_theSplitStartsAtRoughlyHalfAndHalf() {
        let (split, left, right) = makeHalfAndHalfSplit()
        XCTAssertEqual(left.frame.width, 500, accuracy: 2)
        XCTAssertEqual(right.frame.width, 500, accuracy: 2)
        XCTAssertEqual(SplitViewSwap.ratios(of: split)[1], 0.5, accuracy: 0.01)
    }

    func testSwappingTheRightHandViewKeepsItsWidth() {
        let (split, left, right) = makeHalfAndHalfSplit()
        let replacement = NSView(frame: .zero)   // a fresh view has no size, like a new TabRegionView

        SplitViewSwap.replace(right, with: replacement, in: split)

        XCTAssertEqual(replacement.frame.width, 500, accuracy: 2,
                       "the replacement must take over the old view's extent, not collapse to its minimum (the 34pt-sliver bug)")
        XCTAssertEqual(left.frame.width, 500, accuracy: 2,
                       "the sibling must not swallow the space either")
    }

    func testSwapPutsTheReplacementAtTheSameIndex() {
        let (split, left, right) = makeHalfAndHalfSplit()
        let replacement = NSView(frame: .zero)

        SplitViewSwap.replace(right, with: replacement, in: split)

        XCTAssertEqual(split.arrangedSubviews.count, 2)
        XCTAssertTrue(split.arrangedSubviews[0] === left)
        XCTAssertTrue(split.arrangedSubviews[1] === replacement)
        XCTAssertNil(right.superview, "the old view must be detached")
    }

    func testReturnsTheRatiosAsTheyWereBeforeTheSwap() {
        let (split, _, right) = makeHalfAndHalfSplit()
        let before = SplitViewSwap.ratios(of: split)

        let returned = SplitViewSwap.replace(right, with: NSView(frame: .zero), in: split)

        XCTAssertEqual(returned?.count, 2)
        XCTAssertEqual(returned?[0] ?? 0, before[0], accuracy: 0.0001)
        XCTAssertEqual(returned?[1] ?? 0, before[1], accuracy: 0.0001)
    }

    func testAnOperatorDraggedRatioIsPreservedNotResetToHalf() {
        let (split, left, right) = makeHalfAndHalfSplit()
        split.setPosition(300, ofDividerAt: 0)   // operator dragged the divider left
        split.adjustSubviews()
        let rightBefore = right.frame.width

        SplitViewSwap.replace(right, with: NSView(frame: .zero), in: split)

        XCTAssertEqual(split.arrangedSubviews[1].frame.width, rightBefore, accuracy: 2)
        XCTAssertEqual(left.frame.width, 300, accuracy: 2)
    }

    func testSwappingAViewThatIsNotArrangedInTheSplitTouchesNothing() {
        let (split, left, right) = makeHalfAndHalfSplit()
        let stranger = NSView(frame: .zero)

        let result = SplitViewSwap.replace(stranger, with: NSView(frame: .zero), in: split)

        XCTAssertNil(result)
        XCTAssertEqual(split.arrangedSubviews.count, 2)
        XCTAssertTrue(split.arrangedSubviews[0] === left)
        XCTAssertTrue(split.arrangedSubviews[1] === right)
    }

    /// The naive swap `replaceInPlace` used to do, kept as a control: if this
    /// ever stops collapsing, the helper's frame-preservation is no longer
    /// what makes the tests above pass and they should be re-examined.
    func testControl_theNaiveSwapCollapsesTheNewViewToItsMinimum() {
        let (split, _, right) = makeHalfAndHalfSplit()
        let replacement = NSView(frame: .zero)

        split.removeArrangedSubview(right)
        right.removeFromSuperview()
        split.insertArrangedSubview(replacement, at: 1)
        split.adjustSubviews()

        XCTAssertLessThan(replacement.frame.width, 100,
                          "control: a fresh view inserted without a frame does NOT get half the split")
    }
}
