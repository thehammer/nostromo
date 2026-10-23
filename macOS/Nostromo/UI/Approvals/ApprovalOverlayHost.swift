import AppKit
import Combine
import NostromoKit

// AP2a: the layer that floats the approval card over the bottom of a transcript pane.
//
// A transparent view pinned to the scroll view's frame (added above it by `ReplView`,
// like `JumpToLatestOverlay`). It hit-tests only inside the card, so every click
// elsewhere falls through to the transcript and the composer. It hosts at most one
// card for its focus: the one the person is on (`1 of 3`, paged with ‹ ›; arrival order, and a
// newer request never moves the person off the one they are reading). Above the card, the
// production-shell guard's bar (AP2b), when the guard blocked something in the last minute.
// Every `ReplView` showing the focus has its own host over the one shared `ApprovalStore`, so two
// windows show the same requests and a resolution made in one reaches the other.
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

    /// The guard bar on screen, if the guard blocked something in the last minute (AP2b).
    private(set) var guardBar: GuardBlockedBar?

    /// What the guard bar says now, for `approvals list`.
    var guardBarText: String? { guardBar?.textLabel.stringValue }

    /// Where this window is in the focus's requests (`1 of 3`). Nil with none.
    var page: ApprovalPage? {
        ApprovalPaging.page(ids: store.visible(tag: focusTag).map(\.request.id), current: currentRequestID)
    }

    /// Show the request before / after the one on screen. Paging answers nothing.
    func showPrevious() { if let id = page?.previousID { show(requestID: id) } }
    func showNext() { if let id = page?.nextID { show(requestID: id) } }

    private let store: ApprovalStore
    private let agentName: (() -> String?)?
    /// The request this window shows (its own place among the focus's requests).
    private var currentRequestID: String?
    private let windowIDProvider: (() -> String)?
    private let permit: ApprovalCardView.GesturePermit?
    private let reduceMotion: () -> Bool
    private let cardArmDelay: TimeInterval
    private let cardIsOnScreen: (() -> Bool)?
    private var subscription: AnyCancellable?
    /// Set while a card is fading out; a newer card or a refresh cancels it.
    private var fadingCard: ApprovalCardView?

    init(tag: String, store: ApprovalStore,
         agentName: (() -> String?)? = nil,
         windowID: (() -> String)? = nil,
         permit: ApprovalCardView.GesturePermit? = nil,
         armDelay: TimeInterval = ApprovalOverlayHost.armDelay,
         isOnScreen: (() -> Bool)? = nil,
         reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.focusTag = tag
        self.store = store
        self.agentName = agentName
        self.windowIDProvider = windowID
        self.permit = permit
        self.reduceMotion = reduceMotion
        self.cardArmDelay = armDelay
        self.cardIsOnScreen = isOnScreen
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

    /// Gap between the guard bar and the card under it.
    static let barGap: CGFloat = 6

    private func layoutCard() {
        let width = max(0, bounds.width - Self.leadingInset - Self.trailingInset)
        guard width > 0 else { return }
        let barSpace = guardBar == nil ? 0 : GuardBlockedBar.height + Self.barGap
        var top = Self.bottomInset
        if let card {
            let height = card.preferredHeight(forWidth: width, maxHeight: bounds.height * Self.maxHeightFraction,
                                              hardMaxHeight: bounds.height - 2 * Self.bottomInset - barSpace)
            let frame = NSRect(x: Self.leadingInset, y: Self.bottomInset, width: width, height: height)
            if card.frame != frame { card.frame = frame }
            top = frame.maxY + Self.barGap
        }
        if let bar = guardBar {
            let frame = NSRect(x: Self.leadingInset, y: top, width: width, height: GuardBlockedBar.height)
            if bar.frame != frame { bar.frame = frame }
        }
    }

    // MARK: Following the store

    /// Show what the store says this focus should show: the request this window is on (the oldest
    /// until the person pages), the guard bar, or nothing.
    func refresh() {
        refreshGuardBar()
        guard let page, let entry = store.entry(id: page.currentID) else {
            currentRequestID = nil
            fadeOutCard()
            return
        }
        currentRequestID = page.currentID
        if let card, card.request.id == entry.request.id, fadingCard !== card {
            card.update(entry: entry)
            card.setPage(page)
            return
        }
        replaceCard(with: entry, page: page)
    }

    private func show(requestID: String) {
        currentRequestID = requestID
        refresh()
    }

    private func replaceCard(with entry: ApprovalEntry, page: ApprovalPage) {
        removeCardNow()
        let new = ApprovalCardView(entry: entry, store: store, windowID: { [weak self] in self?.currentWindowID() ?? "w0" },
                                   permit: permit, armDelay: cardArmDelay, isOnScreen: cardIsOnScreen)
        new.onNeedsLayout = { [weak self] in self?.needsLayout = true }
        new.onShowRequest = { [weak self] id in self?.show(requestID: id) }
        new.setPage(page)
        addSubview(new)
        card = new
        if store.claimAnnouncement(entry.request.id) {
            // Announced once on arrival, politely: no focus change, no interruption of what is being read.
            NSAccessibility.post(element: new, notification: .announcementRequested,
                                 userInfo: [.announcement: ApprovalDisplayModel.contextText(ApprovalKinds.announcement(for: entry.request), keepingLineFeeds: false),
                                            .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        needsLayout = true
    }

    /// The guard bar follows the store's notice for this focus. It is never announced and never takes focus.
    private func refreshGuardBar() {
        guard let notice = store.guardNotice(tag: focusTag) else {
            guard let bar = guardBar else { return }
            bar.removeFromSuperview()
            guardBar = nil
            needsLayout = true
            return
        }
        let text = ApprovalGuardBarText.line(agent: agentName?().map(ApprovalKinds.capitalized), summary: notice.frame.summary)
        if let bar = guardBar {
            if bar.textLabel.stringValue != text { bar.setText(text) }
            return
        }
        let bar = GuardBlockedBar(text: text)
        bar.onClose = { [weak self] in
            guard let self else { return }
            self.store.dismissGuardNotice(tag: self.focusTag)
        }
        addSubview(bar)
        guardBar = bar
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
