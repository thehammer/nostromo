import Foundation

/// Whether showing an anchor should move the viewport (W2 —
/// curated-agent-views; generalised from a line number to any integer target
/// position in W3, so the same decision serves `ConversationContentView`'s
/// comment anchoring as well as `CodeContentView`'s line anchoring).
///
/// A separate pure type because one of this wedge's product criteria —
/// *"showing an anchor already within the viewport of the frontmost tab does
/// not change scroll position"* — is otherwise only observable by watching a
/// real `NSScrollView` not move, which is not a thing a host-less test bundle
/// can assert. Extracting the decision is the only form in which that criterion
/// is testable, so the view's job shrinks to obeying whatever this returns.
///
/// The motivating case is re-emphasis: an agent that re-shows the same
/// content to mark a second range must not yank the operator's viewport back
/// to the original anchor. Scrolling is for arriving somewhere new.
///
/// `target` is deliberately a bare `Int` rather than an enum of "line" vs.
/// "comment row" — both call sites already have their own way of resolving an
/// `Anchor` to an integer position (a line number for code, a row index for a
/// rendered comment), and this type's whole job is the same for either: given
/// a position and what's currently visible, decide whether to move.
enum ScrollDecision: Equatable {
    /// Leave the viewport exactly where it is.
    case none
    /// Bring `target` into view (the view centres it).
    case scrollTo(target: Int)

    /// Decide from the requested anchor and what is currently on screen.
    ///
    /// - `anchor` is `nil` when the address carries no anchor at all —
    ///   there is nothing to arrive at, so nothing moves.
    /// - `visibleRange` is `nil` before the view has been laid out and knows
    ///   what it is showing. That is a first paint, and a first paint always
    ///   honours its anchor.
    static func decide(anchor: Int?, visibleRange: ClosedRange<Int>?) -> ScrollDecision {
        guard let anchor else { return .none }
        guard let visibleRange else { return .scrollTo(target: anchor) }
        return visibleRange.contains(anchor) ? .none : .scrollTo(target: anchor)
    }
}
