import Foundation

/// Whether showing an anchor should move the viewport (W2/W3 —
/// curated-agent-views; ported into `NostromoKit` in `ios-curated-view-parity`
/// W7).
///
/// A separate pure type because one of this wedge's product criteria —
/// "showing an anchor already within the viewport does not change scroll
/// position" — is otherwise only observable by watching a real scroll view
/// not move, which no headless/host-less/device-less test bundle can assert.
/// Extracting the decision is the only form in which that criterion is
/// testable, so the view's job shrinks to obeying whatever this returns.
///
/// The motivating case is re-emphasis: an agent that re-shows the same
/// content to mark a second range must not yank the operator's viewport back
/// to the original anchor. Scrolling is for arriving somewhere new.
///
/// `target` is deliberately a bare `Int` rather than an enum of "line" vs.
/// "comment row" — every call site already has its own way of resolving an
/// `Anchor` to an integer position (a line number for code, a row index for a
/// rendered comment), and this type's whole job is the same for either: given
/// a position and what's currently visible, decide whether to move.
///
/// This is distinct from `ScrollRestore` (`Layout/FocusRegionState.swift`),
/// which decides whether to restore a *saved* scroll position after a
/// width-class rebuild rather than whether to honour a freshly-requested
/// *anchor* — the same three-line rule, answering a different question, kept
/// as a separate type because the two call sites reason about different
/// inputs (a `PaneAddress` anchor vs. a previously saved key).
///
/// A **port**, not a shared move — see `CodeDocument`'s doc comment.
public enum ScrollDecision: Equatable {
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
    public static func decide(anchor: Int?, visibleRange: ClosedRange<Int>?) -> ScrollDecision {
        guard let anchor else { return .none }
        guard let visibleRange else { return .scrollTo(target: anchor) }
        return visibleRange.contains(anchor) ? .none : .scrollTo(target: anchor)
    }
}
