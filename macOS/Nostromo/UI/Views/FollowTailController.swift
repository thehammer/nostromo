import AppKit

/// Owns "is this transcript pane following its newest message?" for one
/// `ReplView`: the pinned flag, the clip-view bounds observer that updates it,
/// the "Jump to latest" overlay it drives, the scroller it configures, and the
/// catch-up owed to a pane that was pinned while it could not be laid out.
///
/// Extracted from `ReplView` so the wiring — not just the pure
/// `FollowTailPolicy` rule — is exercised against real AppKit objects
/// (`FollowTailControllerTests`). `ReplView` supplies the few things only it
/// knows (document height, usable width, whether its pass is running, how to
/// schedule a pass) as closures.
final class FollowTailController {

    /// One change of the pinned flag, handed to `onFlip` for logging.
    struct Flip {
        let pinned: Bool
        let cause: FollowTailPolicy.Cause
        /// New clip-view origin.y minus the previous one; nil for a flip that
        /// did not come from a bounds change (send, jump, harness).
        let originDeltaY: CGFloat?
        /// Whether the bounds change also resized the clip view; nil as above.
        let sizeChanged: Bool?
    }

    /// Beyond any document height, below AppKit's 2^45 geometry limit.
    ///
    /// "Arbitrarily large" must still be a VALID geometry value: this used to
    /// be `CGFloat.greatestFiniteMagnitude` (~1.8e308), and AppKit logged an
    /// `Invalid view geometry: value is greater than 35184372088832` Fault
    /// (2^45, its limit) on every call — a few per second while a transcript
    /// streams (found in live QA, 2026-10-06). This is far beyond any real
    /// document height (the longest transcript measured was ~1.1e7 points).
    static let scrollToBottomY: CGFloat = 1_000_000_000

    private(set) var isPinned = true

    let scrollView: NSScrollView
    let overlay: JumpToLatestOverlay

    /// Height of the whole transcript as the virtualizer knows it.
    var documentHeight: () -> CGFloat = { 0 }
    /// Width the pane can lay turns out in.
    var contentWidth: () -> CGFloat = { 1 }
    /// True while the pane's own materialization pass is running.
    var isMaterializing: () -> Bool = { false }
    /// Ask the pane for a (coalesced, asynchronous) materialization pass.
    var requestPass: () -> Void = {}
    /// Called on every flip of `isPinned`.
    var onFlip: ((Flip) -> Void)?

    private var lastClipBounds: NSRect = .zero
    private var passSkippedForWidth = false
    /// Between `willStartLiveScroll` and `didEndLiveScroll` (momentum included):
    /// a bounds change now is a trackpad / wheel gesture, not something stray.
    private var liveScrollInFlight = false
    private var observers: [NSObjectProtocol] = []

    init(scrollView: NSScrollView, overlay: JumpToLatestOverlay) {
        self.scrollView = scrollView
        self.overlay = overlay

        // The scroller must stay visible and usable for as long as the pane is
        // scrolled back. An overlay scroller fades ~1 s after the last scroll,
        // leaving a "Jump to latest" pill but no scrollbar; a legacy scroller
        // keeps its track on screen whenever the document is taller than the
        // viewport, which is always true while un-pinned. (It still hides when
        // everything fits.) Light knob: the default dark knob is invisible on
        // `Theme.bg`.
        scrollView.scrollerStyle = .legacy
        scrollView.scrollerKnobStyle = .light
        scrollView.autohidesScrollers = true

        overlay.onJump = { [weak self] in self?.pinToBottomAndScroll(cause: .jumpToLatest) }
        overlay.setFollowingTail(isPinned)

        let clip = scrollView.contentView
        clip.postsBoundsChangedNotifications = true
        lastClipBounds = clip.bounds

        let center = NotificationCenter.default
        // Scroller drags, Home/End and `scrollToBottom()` move the clip view
        // without a live-scroll notification, which is the entire reason this
        // observer exists. Live-scroll notifications only fire for trackpad /
        // wheel scrolling — the signal that separates "operator is reading
        // history" from "we just auto-scrolled".
        observers.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: nil
        ) { [weak self] _ in self?.clipBoundsDidChange() })
        observers.append(center.addObserver(
            forName: NSScrollView.didLiveScrollNotification, object: scrollView, queue: nil
        ) { [weak self] _ in self?.liveScrollDidChange() })
        observers.append(center.addObserver(
            forName: NSScrollView.willStartLiveScrollNotification, object: scrollView, queue: nil
        ) { [weak self] _ in self?.liveScrollInFlight = true })
        observers.append(center.addObserver(
            forName: NSScrollView.didEndLiveScrollNotification, object: scrollView, queue: nil
        ) { [weak self] _ in self?.liveScrollInFlight = false })
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: Pinning

    /// The one place `isPinned` changes.
    func setPinned(_ pinned: Bool, cause: FollowTailPolicy.Cause,
                   originDeltaY: CGFloat? = nil, sizeChanged: Bool? = nil) {
        guard pinned != isPinned else { return }
        isPinned = pinned
        overlay.setFollowingTail(pinned)
        onFlip?(Flip(pinned: pinned, cause: cause,
                     originDeltaY: originDeltaY, sizeChanged: sizeChanged))
    }

    /// Re-pin and bring the newest content into view — the operator sent a
    /// message / answered / ran a quick action, or clicked "Jump to latest".
    func pinToBottomAndScroll(cause: FollowTailPolicy.Cause) {
        setPinned(true, cause: cause)
        scrollToBottom()
        requestPass()
    }

    func scrollToBottom() {
        // Scroll to an arbitrarily large Y — AppKit clamps to the actual maximum.
        // Avoids reading `documentView.frame`, which on a dirty NSView triggers a
        // synchronous layout pass. See `scrollToBottomY`.
        scrollView.contentView.scroll(NSPoint(x: 0, y: Self.scrollToBottomY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    // MARK: Bounds observation

    private func liveScrollDidChange() {
        // The bounds notification already classified this tick; a live-scroll
        // end can still land the viewport back at the bottom.
        classifyClipBoundsChange(cause: .userScroll)
        requestPass()
    }

    private func clipBoundsDidChange() {
        // A bounds change observed while a pass is running was caused by that
        // pass — the notification is delivered synchronously from inside its own
        // scroll and frame calls — so it must not be read as operator intent.
        classifyClipBoundsChange(cause: liveScrollInFlight ? .userScroll : .boundsChange)
        guard !isMaterializing() else { return }
        requestPass()
    }

    /// Fold the clip view's latest bounds into the follow-tail state.
    ///
    /// Always records the new bounds (even for a change the pass itself made,
    /// so the next delta is measured from where the viewport really is), then
    /// lets `FollowTailPolicy` decide.
    private func classifyClipBoundsChange(cause: FollowTailPolicy.Cause) {
        let bounds = scrollView.contentView.bounds
        let previous = lastClipBounds
        lastClipBounds = bounds
        let originDeltaY = bounds.origin.y - previous.origin.y
        let sizeChanged = FollowTailPolicy.sizeChanged(from: previous, to: bounds)
        let next = FollowTailPolicy.pinnedAfterBoundsChange(
            current: isPinned,
            originDeltaY: originDeltaY,
            sizeChanged: sizeChanged,
            isMaterializing: isMaterializing(),
            documentHeight: documentHeight(),
            visibleMaxY: bounds.maxY)
        setPinned(next, cause: cause, originDeltaY: originDeltaY, sizeChanged: sizeChanged)
    }

    // MARK: Catch-up

    /// The pane's pass found no usable width and did nothing.
    func notePassSkippedForWidth() { passSkippedForWidth = true }

    /// The pane's pass ran.
    func notePassRan() { passSkippedForWidth = false }

    /// A pane that was pinned but could not do its pass (no width, window
    /// hidden/occluded and just re-shown) owes itself a pass that scrolls to the
    /// bottom, or it sits parked partway up until the next unrelated event.
    /// Call when the pane may have just become usable (layout, window change).
    func paneMayHaveBecomeUsable() {
        guard FollowTailPolicy.shouldCatchUp(isPinned: isPinned,
                                             contentWidth: contentWidth(),
                                             passWasSkipped: passSkippedForWidth) else { return }
        requestPass()
    }

    /// Re-show (un-hide, un-occlude): a pinned pane re-runs a pass, which ends
    /// by scrolling to the bottom. Idempotent when it is already there.
    func paneWasShown() {
        guard isPinned else { return }
        requestPass()
    }
}
