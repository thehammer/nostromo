import Foundation

/// Whether showing an anchor should move the viewport (W2 —
/// curated-agent-views).
///
/// A separate pure type because one of this wedge's product criteria —
/// *"showing an anchor already within the viewport of the frontmost tab does
/// not change scroll position"* — is otherwise only observable by watching a
/// real `NSScrollView` not move, which is not a thing a host-less test bundle
/// can assert. Extracting the decision is the only form in which that criterion
/// is testable, so the view's job shrinks to obeying whatever this returns.
///
/// The motivating case is re-emphasis: an agent that re-shows the same file to
/// mark a second range must not yank the operator's viewport back to the
/// original anchor. Scrolling is for arriving somewhere new.
enum ScrollDecision: Equatable {
    /// Leave the viewport exactly where it is.
    case none
    /// Bring `line` into view (the view centres it).
    case scrollTo(line: Int)

    /// Decide from the requested anchor and what is currently on screen.
    ///
    /// - `anchorLine` is `nil` when the address carries no anchor at all —
    ///   there is nothing to arrive at, so nothing moves.
    /// - `visibleLines` is `nil` before the view has been laid out and knows
    ///   what it is showing. That is a first paint, and a first paint always
    ///   honours its anchor.
    static func decide(anchorLine: Int?, visibleLines: ClosedRange<Int>?) -> ScrollDecision {
        guard let anchorLine else { return .none }
        guard let visibleLines else { return .scrollTo(line: anchorLine) }
        return visibleLines.contains(anchorLine) ? .none : .scrollTo(line: anchorLine)
    }
}
