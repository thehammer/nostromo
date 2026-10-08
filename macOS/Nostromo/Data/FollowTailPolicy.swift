import CoreGraphics

/// Decides when a transcript pane is "following the tail" (`isPinnedToBottom`).
///
/// ## Why this is not a one-liner
///
/// The pane used to recompute "am I within 40 pt of the bottom?" on *every*
/// clip-view bounds change. A bounds change is not evidence the operator
/// scrolled: a pane resize, a re-layout, a collapsed split coming back, or a
/// window being re-shown all post one. And the virtualizer's `documentHeight`
/// grows the moment a turn is appended — a main-queue hop *before* the pass
/// that scrolls the clip view down to it. A bounds change landing in that gap
/// saw "300 pt from the bottom", silently cleared `isPinnedToBottom`, and the
/// pane stopped following for good: nothing re-armed it until the operator
/// scrolled back within 40 pt of the bottom by hand. Intermittent, per pane,
/// and worst for a pane that was hidden or occluded while content streamed —
/// exactly the "one window keeps up, another lags" report.
///
/// The rule here: **only the operator scrolling the viewport away from the
/// bottom may un-pin.** A bounds change that resized the clip view is never a
/// scroll. A bounds change caused by a materialization pass is never operator
/// intent either. What remains — origin moved, size did not, no pass running —
/// is a wheel/trackpad tick, a scroller-knob drag, or Home/End/Page keys.
enum FollowTailPolicy {

    /// "Within this many points of the true bottom" counts as at the bottom.
    /// Demanding an exact match would fight sub-pixel rounding.
    static let pinThreshold: CGFloat = 40

    /// What changed `isPinnedToBottom`. Recorded with every flip so an
    /// occurrence in the field can be attributed (see `ReplView.setPinned`).
    enum Cause: String {
        /// The operator scrolled (wheel, trackpad, scroller knob, keys).
        case userScroll
        /// The operator sent a message / answered / ran a quick action.
        case send
        /// The operator clicked "Jump to latest".
        case jumpToLatest
        /// The load harness's scripted scroll round trip.
        case harness
    }

    /// Distance from the bottom of the document to the bottom of the viewport.
    static func distanceFromBottom(documentHeight: CGFloat, visibleMaxY: CGFloat) -> CGFloat {
        documentHeight - visibleMaxY
    }

    static func isNearBottom(documentHeight: CGFloat, visibleMaxY: CGFloat) -> Bool {
        distanceFromBottom(documentHeight: documentHeight, visibleMaxY: visibleMaxY) < pinThreshold
    }

    /// The pinned state after the clip view's bounds changed.
    ///
    /// - Parameters:
    ///   - originDeltaY: new `bounds.origin.y` minus the previous one. Negative
    ///     means the viewport moved toward the top of the transcript.
    ///   - sizeChanged: the clip view's bounds *size* changed (pane resized,
    ///     split collapsed/restored, input bar grew, window re-shown).
    ///   - isMaterializing: the change was made by our own pass.
    static func pinnedAfterBoundsChange(current: Bool,
                                        originDeltaY: CGFloat,
                                        sizeChanged: Bool,
                                        isMaterializing: Bool,
                                        documentHeight: CGFloat,
                                        visibleMaxY: CGFloat) -> Bool {
        // Not scrolls: never touch the state.
        guard !isMaterializing, !sizeChanged else { return current }
        // Back at the bottom by any route re-arms following.
        if isNearBottom(documentHeight: documentHeight, visibleMaxY: visibleMaxY) { return true }
        // Away from the bottom: only a move *up* un-pins. A zero or downward
        // delta here means the document grew under a viewport the operator did
        // not move (a stray tick, momentum tail, our own scroll racing the
        // geometry) — keep following.
        return originDeltaY < 0 ? false : current
    }

    /// `pinnedAfterBoundsChange` fed straight from two successive clip-view
    /// bounds, so the scroll-vs-resize classification lives (and is tested) here
    /// rather than in the view.
    static func pinnedAfterBoundsChange(current: Bool,
                                        previousBounds: CGRect,
                                        bounds: CGRect,
                                        isMaterializing: Bool,
                                        documentHeight: CGFloat) -> Bool {
        let sizeChanged = abs(bounds.width - previousBounds.width) > 0.5
                       || abs(bounds.height - previousBounds.height) > 0.5
        return pinnedAfterBoundsChange(
            current: current,
            originDeltaY: bounds.origin.y - previousBounds.origin.y,
            sizeChanged: sizeChanged,
            isMaterializing: isMaterializing,
            documentHeight: documentHeight,
            visibleMaxY: bounds.maxY)
    }

    /// Whether a pane should schedule a catch-up pass because it just became
    /// usable (non-zero width, back in a window, un-hidden) after a pass was
    /// skipped or content arrived while it could not be laid out.
    static func shouldCatchUp(isPinned: Bool, contentWidth: CGFloat, passWasSkipped: Bool) -> Bool {
        isPinned && passWasSkipped && contentWidth > 1
    }

    /// Whether the "Jump to latest" affordance (and the always-visible
    /// scroller) should show.
    static func showsJumpToLatest(isPinned: Bool) -> Bool { !isPinned }
}
