import AppKit

/// Swapping one arranged subview of an `NSSplitView` for another without
/// disturbing the divider layout.
///
/// Why this exists: `DynamicFocusView.applyTabMembership` replaces a
/// `TabRegionView` with a freshly built one whenever a tab opens or closes.
/// A brand-new view has no size, so inserting it as an arranged subview makes
/// `NSSplitView` hand it its *minimum* extent (~34pt) and give everything else
/// to its sibling. Measured live (2026-10-06): the PR detail region opened at
/// half the window with one tab, and collapsed to a 34pt sliver the moment the
/// second tab (the diff) joined it. The ratio had already been applied once
/// and cleared, so nothing ever put the divider back.
///
/// The swap therefore (1) gives the new view the old view's exact frame before
/// it is inserted and (2) returns the split's ratios as they stood *before*
/// the swap, so the caller can re-assert them through the same
/// verified-and-retried path every other ratio application uses.
enum SplitViewSwap {

    /// Each arranged subview's share of the split along its axis, summing to 1.
    /// Equal shares when the split has no measurable size yet.
    static func ratios(of split: NSSplitView) -> [Double] {
        let subviews = split.subviews
        let sizes = subviews.map { split.isVertical ? $0.frame.size.width : $0.frame.size.height }
        let sum = sizes.reduce(0, +)
        guard sum > 0 else { return Array(repeating: 1.0 / Double(max(subviews.count, 1)), count: subviews.count) }
        return sizes.map { Double($0 / sum) }
    }

    /// Replace `old` with `new` at the same index in `split`. Returns the
    /// split's ratios as they were immediately before the swap (to re-assert
    /// afterwards), or `nil` when `old` isn't an arranged subview of `split`
    /// — in which case nothing is touched.
    @discardableResult
    static func replace(_ old: NSView, with new: NSView, in split: NSSplitView) -> [Double]? {
        guard let index = split.arrangedSubviews.firstIndex(of: old) else { return nil }
        let before = ratios(of: split)
        new.frame = old.frame
        split.removeArrangedSubview(old)
        old.removeFromSuperview()
        split.insertArrangedSubview(new, at: index)
        return before
    }
}
