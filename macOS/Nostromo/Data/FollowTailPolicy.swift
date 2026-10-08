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
/// and plausibly worst for a pane that was hidden or occluded while content
/// streamed (a hypothesis for the "one window keeps up, another lags" report,
/// not an observed cause: occlusion alone posts no bounds change).
///
/// The rule here: **only the operator scrolling the viewport away from the
/// bottom may un-pin.** A bounds change that resized the clip view is never a
/// scroll (it can only *re*-pin, if it left the viewport at the bottom). A
/// bounds change caused by a materialization pass is never operator intent
/// either. What remains — origin moved, size did not, no pass running —
/// is a wheel/trackpad tick, a scroller-knob drag, or Home/End/Page keys.
enum FollowTailPolicy {

    /// "Within this many points of the true bottom" counts as at the bottom.
    /// Demanding an exact match would fight sub-pixel rounding.
    static let pinThreshold: CGFloat = 40

    /// An upward origin move smaller than this is jitter (sub-pixel rounding,
    /// an AppKit clamp), not the operator scrolling, and must not un-pin.
    static let unpinEpsilon: CGFloat = 0.5

    /// What changed `isPinnedToBottom`. Recorded with every flip so an
    /// occurrence in the field can be attributed (see `ReplView.setPinned`).
    enum Cause: String {
        /// The operator scrolled (wheel, trackpad, scroller knob, keys).
        case userScroll
        /// A bounds change moved the viewport away from the bottom with no
        /// live scroll in flight (scroller-knob drag, keys, or something
        /// stray). Not proof the operator scrolled.
        case boundsChange
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
        // Our own pass made this change: never operator intent.
        guard !isMaterializing else { return current }
        // Back at the bottom by any route re-arms following — including a
        // resize that clamped an un-pinned viewport down onto the bottom, where
        // a "Jump to latest" pill over the newest message would be absurd.
        if isNearBottom(documentHeight: documentHeight, visibleMaxY: visibleMaxY) { return true }
        // A resize that left the viewport away from the bottom is not a scroll:
        // it never un-pins (the document may simply have grown under it).
        guard !sizeChanged else { return current }
        // Away from the bottom: only a clear move *up* un-pins. A zero, tiny or
        // downward delta here means the document grew under a viewport the
        // operator did not move (a stray tick, momentum tail, our own scroll
        // racing the geometry) — keep the current state.
        return originDeltaY < -unpinEpsilon ? false : current
    }

    /// Whether the clip view's bounds *size* changed between two notifications.
    static func sizeChanged(from previous: CGRect, to bounds: CGRect) -> Bool {
        abs(bounds.width - previous.width) > 0.5 || abs(bounds.height - previous.height) > 0.5
    }

    /// `pinnedAfterBoundsChange` fed straight from two successive clip-view
    /// bounds, so the scroll-vs-resize classification lives (and is tested) here
    /// rather than in the view.
    static func pinnedAfterBoundsChange(current: Bool,
                                        previousBounds: CGRect,
                                        bounds: CGRect,
                                        isMaterializing: Bool,
                                        documentHeight: CGFloat) -> Bool {
        let resized = Self.sizeChanged(from: previousBounds, to: bounds)
        return pinnedAfterBoundsChange(
            current: current,
            originDeltaY: bounds.origin.y - previousBounds.origin.y,
            sizeChanged: resized,
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
