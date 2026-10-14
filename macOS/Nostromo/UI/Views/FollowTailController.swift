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
        applyScrollerStyle()

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
        // AppKit re-applies the system's preferred scroller style to every
        // scroll view when it changes (a mouse or trackpad is attached or
        // detached, or "Show scroll bars" is changed). Without re-asserting
        // ours, the scroller silently goes back to overlay and fades — the
        // original "pill but no scrollbar" bug.
        observers.append(center.addObserver(
            forName: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.applyScrollerStyle() })
    }

    /// Legacy style + light knob + autohide; see `init` for why. Idempotent.
    func applyScrollerStyle() {
        scrollView.scrollerStyle = .legacy
        scrollView.scrollerKnobStyle = .light
        scrollView.autohidesScrollers = true
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

// MARK: - TranscriptViewportCoordinator

/// Keeps the operator's place in a transcript pane across a materialization pass: the
/// scroll-restoring half of `ReplView.materialize()` (its first and last steps), extracted so
/// tests can drive it with real AppKit objects (`ReplView` itself cannot be built in the logic
/// test bundle).
///
/// Three rules, in priority order, applied at the end of the pass:
/// 1. **The operator toggled a row** (a tool group, or a result fold): that row goes back to
///    the same place on screen. If the pane was following the tail, it keeps following only if
///    the bottom is still in view afterwards (`FollowTailPolicy.pinnedAfterFoldToggle`).
/// 2. **Following the tail**: scroll to the bottom.
/// 3. **Scrolled up**: the item at the top of the viewport stays where it was. The anchor names
///    the item inside its turn (`TurnIsland.anchorItem`), not just the turn, and it is captured
///    *before* a programmatic change is applied (`noteProgrammaticChange`), so a height change
///    inside the anchor turn but above the viewport (a group opening off screen) cannot move the
///    text being read.
final class TranscriptViewportCoordinator {

    private enum Pending {
        /// Rule 1: put the row named by `anchor` (offset 0 into its item) back at `screenY`
        /// below the viewport top.
        case row(TurnListVirtualizer.Anchor, screenY: CGFloat, wasPinned: Bool)
        /// Rule 3: keep the content at the viewport top in place.
        case top(TurnListVirtualizer.Anchor)
    }

    let virtualizer: TurnListVirtualizer
    let scrollView: NSScrollView
    let followTail: FollowTailController
    /// The materialized island of the turn at an index, or nil.
    let islandFor: (_ turnIndex: Int) -> TurnIsland?

    /// The pane's half of `applyFoldChange`: mark the turns for re-measure, re-estimate the
    /// rest, schedule a pass.
    var foldChangeApplied: (Set<UUID>) -> Void = { _ in }

    private var pending: Pending?
    /// The viewport top when `pending` was captured. A pass that finds the viewport has moved
    /// since (the operator scrolled) drops it rather than pulling them back.
    private var pendingViewportTop: CGFloat = 0

    init(virtualizer: TurnListVirtualizer, scrollView: NSScrollView, followTail: FollowTailController,
         islandFor: @escaping (_ turnIndex: Int) -> TurnIsland?) {
        self.virtualizer = virtualizer
        self.scrollView = scrollView
        self.followTail = followTail
        self.islandFor = islandFor
    }

    private var clip: NSClipView { scrollView.contentView }

    // MARK: Before a change

    /// Rule 1: the operator toggled the row `itemKey` (a group key, or `b<i>` for a result) in
    /// the turn at `turnIndex`. Call as the toggle is reported, before the pass that measures
    /// it: the island may already hold the new state, but nothing above the toggled row has
    /// moved, so its screen position is still the one the operator clicked.
    func noteUserToggle(turnIndex: Int, itemKey: String) {
        guard let island = islandFor(turnIndex), let itemTop = island.offset(ofItemKey: itemKey),
              let key = virtualizer.contentKey(at: turnIndex)
        else {
            noteProgrammaticChange()
            return
        }
        let viewportTop = clip.bounds.minY
        let anchor = TurnListVirtualizer.Anchor(key: key, index: turnIndex, offsetWithinTurn: itemTop,
                                                itemKey: itemKey, offsetInItem: 0)
        pending = .row(anchor, screenY: virtualizer.offset(of: turnIndex) + itemTop - viewportTop,
                       wasPinned: followTail.isPinned)
        pendingViewportTop = viewportTop
    }

    /// Rule 3: a programmatic change (streaming, the stuck-turn auto-open, a fold change made
    /// elsewhere) is about to be applied. Captures the reading position first, unless the pane
    /// follows the tail or a position is already pending.
    func noteProgrammaticChange() {
        guard pending == nil, !followTail.isPinned, let anchor = captureAnchor() else { return }
        pending = .top(anchor)
        pendingViewportTop = clip.bounds.minY
    }

    /// The one entry point for a programmatic fold change: capture → `mutation` →
    /// `foldChangeApplied(turnIds)` (re-measure, re-estimate, pass).
    func applyFoldChange(turnIds: Set<UUID>, mutation: () -> Void) {
        noteProgrammaticChange()
        mutation()
        foldChangeApplied(turnIds)
    }

    // MARK: The pass

    /// Step 1 of a materialization pass: name where the operator is reading, before any
    /// height changes, unless that was done before the change that asked for this pass.
    func beginPass() {
        if pending != nil, abs(clip.bounds.minY - pendingViewportTop) > 0.5 { pending = nil }
        noteProgrammaticChange()
    }

    /// Where the viewport will be once `endPass` has put things back, as far as the geometry
    /// knows after `beginPass`. The pass materializes the turns around this rather than around
    /// where the viewport was before the change: an Expand All that grows the turns above the
    /// reading position by more than the overscan would otherwise evict the very turn being read.
    func anticipatedViewport() -> NSRect {
        var viewport = clip.bounds
        let lowest = max(0, virtualizer.documentHeight - viewport.height)
        switch pending {
        case .row(let anchor, let screenY, _)?:
            viewport.origin.y = virtualizer.restoredTop(for: anchor, itemOffset: itemOffset) - screenY
        case _ where followTail.isPinned:
            viewport.origin.y = lowest
        case .top(let anchor)?:
            viewport.origin.y = virtualizer.restoredTop(for: anchor, itemOffset: itemOffset)
        case nil:
            break
        }
        viewport.origin.y = min(max(0, viewport.origin.y), lowest)
        return viewport
    }

    /// Step 5 of a materialization pass, after views are built, measured and positioned and
    /// the document view sized: put the reading position back, or follow the newest content.
    func endPass() {
        defer { pending = nil }
        switch pending {
        case .row(let anchor, let screenY, let wasPinned)?:
            let rowTop = virtualizer.restoredTop(for: anchor, itemOffset: itemOffset)
            scroll(toTop: clamped(rowTop - screenY))
            if wasPinned {
                let pinned = FollowTailPolicy.pinnedAfterFoldToggle(viewportMaxY: clip.bounds.maxY,
                                                                    documentHeight: documentHeight)
                followTail.setPinned(pinned, cause: .foldToggle)
            }
        case _ where followTail.isPinned:
            followTail.scrollToBottom()
        case .top(let anchor)?:
            scroll(toTop: virtualizer.restoredTop(for: anchor, itemOffset: itemOffset))
        case nil:
            break
        }
    }

    // MARK: Helpers

    private func captureAnchor() -> TurnListVirtualizer.Anchor? {
        virtualizer.captureAnchor(viewportTop: clip.bounds.minY) { [islandFor] index, y in
            islandFor(index)?.anchorItem(atY: y)
        }
    }

    private func itemOffset(_ index: Int, _ itemKey: String) -> CGFloat? {
        islandFor(index)?.offset(ofItemKey: itemKey)
    }

    private var documentHeight: CGFloat {
        max(scrollView.documentView?.frame.height ?? 0, virtualizer.documentHeight)
    }

    /// The highest top the clip view can actually scroll to.
    private func clamped(_ top: CGFloat) -> CGFloat {
        min(max(0, top), max(0, documentHeight - clip.bounds.height))
    }

    private func scroll(toTop top: CGFloat) {
        guard abs(top - clip.bounds.minY) > 0.5 else { return }
        clip.scroll(NSPoint(x: 0, y: top))
        scrollView.reflectScrolledClipView(clip)
    }
}
