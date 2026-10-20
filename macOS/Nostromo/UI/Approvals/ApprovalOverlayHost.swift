import AppKit
import Combine
import NostromoKit

// AP2a: the layer that floats the approval card over the bottom of a transcript pane.
//
// A transparent view pinned to the scroll view's frame (added above it by `ReplView`,
// like `JumpToLatestOverlay`). It hit-tests only inside the card, so every click
// elsewhere falls through to the transcript and the composer. It hosts at most one
// card for its focus: the oldest request. (AP2b adds paging `1 of N`; until then the
// card says `+N more`.)
//
// What it must never do, and how:
//   * Move the transcript or the composer. The card is an overlay with a frame of its
//     own; this view never touches the scroll view's or the input bar's frames.
//   * Take focus on arrival. Nothing here calls `makeFirstResponder`, `makeKey…`,
//     `activate` or `orderFront…` (a source scan pins that for the whole folder).
//   * Hold answered state. `ApprovalStore` does; rebuilding the card (a width change, a
//     pane re-materialised) shows the same state and cannot answer again.

final class ApprovalOverlayHost: NSView {

    /// Gap between the card and the bottom of the transcript.
    static let bottomInset: CGFloat = 8
    /// Left and right margin of the card: the transcript column's. The right one also clears the vertical scroller.
    static let leadingInset: CGFloat = 12
    static let trailingInset: CGFloat = 24
    /// The card is never taller than this share of the pane.
    static let maxHeightFraction: CGFloat = 0.6
    static let fadeDuration: TimeInterval = 0.25
    /// How long a card that just appeared keeps Allow once disabled: a click aimed at what was
    /// under the pointer a moment ago must not land on an Allow button that appeared there.
    static let armDelay: TimeInterval = 0.6

    /// The focus this host shows requests for. (Not `tag`: that is `NSView`'s own.)
    let focusTag: String

    /// The card on screen (may be fading out).
    private(set) var card: ApprovalCardView?

    private let store: ApprovalStore
    private let windowIDProvider: (() -> String)?
    private let permit: ApprovalCardView.GesturePermit?
    private let reduceMotion: () -> Bool
    private let cardArmDelay: TimeInterval
    private var subscription: AnyCancellable?
    /// Set while a card is fading out; a newer card or a refresh cancels it.
    private var fadingCard: ApprovalCardView?

    init(tag: String, store: ApprovalStore,
         windowID: (() -> String)? = nil,
         permit: ApprovalCardView.GesturePermit? = nil,
         armDelay: TimeInterval = ApprovalOverlayHost.armDelay,
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.focusTag = tag
        self.store = store
        self.windowIDProvider = windowID
        self.permit = permit
        self.reduceMotion = reduceMotion
        self.cardArmDelay = armDelay
        super.init(frame: .zero)
        subscription = store.changes
            .filter { [focusTag] in $0 == focusTag }
            .sink { [weak self] _ in self?.refresh() }
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// Names the window an answer came from: the injected name, else `w<window number>`.
    private func currentWindowID() -> String {
        windowIDProvider?() ?? window.map { "w\($0.windowNumber)" } ?? "w0"
    }

    // MARK: Hit testing

    /// Only the card takes clicks. `point` is in the superview's coordinates.
    override func hitTest(_ point: NSPoint) -> NSView? {
        OverlayHitTest.hit(in: self, at: point)
    }

    // MARK: Reading

    /// What the card shows right now (empty when there is none).
    var listings: [ApprovalCardListing] {
        card.map { [$0.listing] } ?? []
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        layoutCard()
    }

    private func layoutCard() {
        guard let card else { return }
        let width = max(0, bounds.width - Self.leadingInset - Self.trailingInset)
        guard width > 0 else { return }
        let height = card.preferredHeight(forWidth: width, maxHeight: bounds.height * Self.maxHeightFraction)
        let frame = NSRect(x: Self.leadingInset, y: Self.bottomInset, width: width, height: height)
        if card.frame != frame { card.frame = frame }
    }

    // MARK: Following the store

    /// Show what the store says this focus should show: the oldest request, or nothing.
    func refresh() {
        guard let entry = store.current(tag: focusTag) else {
            fadeOutCard()
            return
        }
        if let card, card.request.id == entry.request.id, fadingCard !== card {
            card.update(entry: entry)
            card.setMoreCount(store.moreCount(tag: focusTag))
            return
        }
        replaceCard(with: entry)
    }

    private func replaceCard(with entry: ApprovalEntry) {
        removeCardNow()
        let new = ApprovalCardView(entry: entry, store: store, windowID: { [weak self] in self?.currentWindowID() ?? "w0" },
                                   permit: permit, armDelay: cardArmDelay)
        new.onNeedsLayout = { [weak self] in self?.needsLayout = true }
        new.setMoreCount(store.moreCount(tag: focusTag))
        addSubview(new)
        card = new
        if store.claimAnnouncement(entry.request.id) {
            // Announced once on arrival, politely: no focus change, no interruption of what is being read.
            NSAccessibility.post(element: new, notification: .announcementRequested,
                                 userInfo: [.announcement: ApprovalKinds.announcement(for: entry.request),
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        needsLayout = true
    }

    private func fadeOutCard() {
        guard let gone = card, fadingCard !== gone else { return }
        gone.countdown.stop()
        if reduceMotion() {
            removeCardNow()
            return
        }
        fadingCard = gone
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeDuration
            gone.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.fadingCard === gone else { return }
            self.removeCardNow()
        })
    }

    private func removeCardNow() {
        card?.countdown.stop()
        card?.removeFromSuperview()
        card = nil
        fadingCard = nil
    }
}
