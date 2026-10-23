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

    /// The one-line bar standing in for the card while the person has it collapsed (AP3). The card
    /// stays in the view tree, hidden, so its countdown, arming and scroll state are all kept.
    private(set) var collapsedBar: ApprovalCollapsedBar?

    /// Whether this window's card is collapsed to its bar.
    var isCollapsed: Bool { collapsedBar != nil }

    /// The guard bar on screen, if the guard blocked something in the last minute (AP2b).
    private(set) var guardBar: GuardBlockedBar?

    /// What the guard bar says now, for `approvals list`.
    var guardBarText: String? { guardBar?.textLabel.stringValue }

    /// Where this window is in the focus's requests (`1 of 3`). Nil with none.
    var page: ApprovalPage? {
        ApprovalPaging.page(ids: store.visible(tag: focusTag).map(\.request.id), current: currentRequestID,
                            fallbackIndex: currentIndex)
    }

    /// Show the request before / after the one on screen. Paging answers nothing.
    func showPrevious() { if let id = page?.previousID { show(requestID: id) } }
    func showNext() { if let id = page?.nextID { show(requestID: id) } }

    private let store: ApprovalStore
    private let agentName: (() -> String?)?
    /// The request this window shows (its own place among the focus's requests).
    private var currentRequestID: String?
    /// Where that request sat in the list, so that when it goes the one that took its place is shown.
    private var currentIndex: Int?
    /// What the person chose and typed on an AskUserQuestion card they paged away from, per request id,
    /// for as long as the request is pending. Only a draft: nothing here is ever sent.
    private var questionDrafts: [String: [ApprovalQuestionSelection]] = [:]
    private let windowIDProvider: (() -> String)?
    private let permit: ApprovalCardView.GesturePermit?
    private let reduceMotion: () -> Bool
    private let cardArmDelay: TimeInterval
    private let cardIsOnScreen: (() -> Bool)?
    /// Gives keyboard focus back to the composer (Esc in the card, or collapsing a focused card). Set
    /// by the pane that owns the composer.
    var focusComposer: (() -> Void)?
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

    /// What the bar says while collapsed, for `approvals list` (nil when expanded).
    var collapsedBarText: String? { collapsedBar?.text }

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
        if let bar = collapsedBar {
            let frame = NSRect(x: Self.leadingInset, y: Self.bottomInset, width: width, height: ApprovalCollapsedBar.height)
            if bar.frame != frame { bar.frame = frame }
            top = frame.maxY + Self.barGap
        } else if let card {
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
        pruneQuestionDrafts()
        guard let page, let entry = store.entry(id: page.currentID) else {
            currentRequestID = nil
            currentIndex = nil
            fadeOutCard()
            return
        }
        currentRequestID = page.currentID
        currentIndex = page.position - 1
        if let card, card.request.id == entry.request.id, fadingCard !== card {
            card.update(entry: entry)
            card.setPage(page)
            syncCollapsed(entry)
            return
        }
        replaceCard(with: entry, page: page)
        syncCollapsed(entry)
    }

    /// Show the bar instead of the card while the store says this request is collapsed (and still
    /// waiting: an outcome is always shown on the full card).
    private func syncCollapsed(_ entry: ApprovalEntry) {
        let wanted = store.isCollapsed(entry.request.id) && !entry.isEnded
        guard let card else { return }
        if wanted {
            let bar: ApprovalCollapsedBar
            if let existing = collapsedBar, existing.requestID == entry.request.id {
                bar = existing
            } else {
                collapsedBar?.removeFromSuperview()
                bar = ApprovalCollapsedBar(request: card.request, model: card.model,
                                           agentName: ApprovalKinds.capitalized(card.request.agent.name))
                bar.onExpand = { [weak self] in
                    guard let self, let id = self.currentRequestID else { return }
                    self.store.setCollapsed(id, false)
                }
                addSubview(bar)
                collapsedBar = bar
                // A focused card is about to be hidden: keyboard focus goes back to the composer first.
                if card.hasKeyboardFocus { focusComposer?() }
            }
            card.isHidden = true
            needsLayout = true
        } else if collapsedBar != nil {
            collapsedBar?.removeFromSuperview()
            collapsedBar = nil
            card.isHidden = false
            needsLayout = true
        }
    }

    /// ⌥⌘A: move keyboard focus into the visible card of one of the focuses `window` shows. An
    /// expanded bar is expanded first. False (the caller beeps) when no card is there to focus.
    @discardableResult
    static func focusCard(in window: NSWindow?) -> Bool {
        guard let content = window?.contentView else { return false }
        for host in visibleHosts(in: content) where host.focusVisibleCard() { return true }
        return false
    }

    /// Every host below `view` that is on screen (not hidden, itself or by an ancestor).
    static func visibleHosts(in view: NSView) -> [ApprovalOverlayHost] {
        var hosts: [ApprovalOverlayHost] = []
        func walk(_ v: NSView) {
            if let host = v as? ApprovalOverlayHost, !host.isHiddenOrHasHiddenAncestor { hosts.append(host) }
            v.subviews.forEach(walk)
        }
        walk(view)
        return hosts
    }

    private func focusVisibleCard() -> Bool {
        guard let card, let id = currentRequestID, let entry = store.entry(id: id), !entry.isEnded else { return false }
        if store.isCollapsed(id) {
            store.setCollapsed(id, false)   // the store's change refreshes this host synchronously
            layoutSubtreeIfNeeded()
        }
        return card.focusCard()
    }

    private func show(requestID: String) {
        currentRequestID = requestID
        refresh()
    }

    private func replaceCard(with entry: ApprovalEntry, page: ApprovalPage) {
        if let old = card, let selections = old.questionForm?.selections { questionDrafts[old.request.id] = selections }
        removeCardNow()
        // The scroll gate and the arm delay start over on every card: paging is the safe direction.
        let new = ApprovalCardView(entry: entry, store: store, windowID: { [weak self] in self?.currentWindowID() ?? "w0" },
                                   permit: permit, armDelay: cardArmDelay, isOnScreen: cardIsOnScreen,
                                   questionDraft: questionDrafts[entry.request.id])
        new.onNeedsLayout = { [weak self] in self?.needsLayout = true }
        new.onShowRequest = { [weak self] id in self?.show(requestID: id) }
        new.onReturnToComposer = { [weak self] in self?.focusComposer?() }
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

    /// A draft lives only while its request is pending.
    private func pruneQuestionDrafts() {
        guard !questionDrafts.isEmpty else { return }
        let live = Set(store.visible(tag: focusTag).filter { !$0.isEnded }.map(\.request.id))
        questionDrafts = questionDrafts.filter { live.contains($0.key) }
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
        collapsedBar?.removeFromSuperview()
        collapsedBar = nil
        gone.isHidden = false
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
        collapsedBar?.removeFromSuperview()
        collapsedBar = nil
        card?.countdown.stop()
        card?.removeFromSuperview()
        card = nil
        fadingCard = nil
        needsLayout = true   // the guard bar, if any, drops back to the card's slot
    }
}

// MARK: - Collapsed bar (AP3)

/// The card collapsed to one line: `⚠ Cody needs approval · Bash · rm -rf build/ …`, the countdown, and a
/// chevron that expands it. It floats where the card did and keeps counting down; the request is still
/// pending. It is never first responder on its own (the chevron can be reached with Tab like any button).
final class ApprovalCollapsedBar: NSView {

    static let height: CGFloat = 28
    static let chevronWidth: CGFloat = 24

    let requestID: String
    /// The line: `⚠ Cody needs approval · Bash · rm -rf build/ …`.
    let textLabel = NSTextField(labelWithString: "")
    let countdown: ApprovalCountdownLabel
    let expandButton = ApprovalButton(title: "", target: nil, action: nil)

    /// The person pressed the chevron.
    var onExpand: (() -> Void)?

    /// The line as shown.
    var text: String { textLabel.stringValue }
    /// The countdown as shown (`denies in 14:32`): it ticks while the bar is on screen.
    var countdownText: String { countdown.label.stringValue }

    /// `nowMs` is the clock the countdown reads (a test injects one).
    init(request: ApprovalRequestWire, model: ApprovalDisplayModel, agentName: String,
         nowMs: @escaping () -> UInt64 = { UInt64(max(0, Date().timeIntervalSince1970 * 1000)) }) {
        requestID = request.id
        countdown = ApprovalCountdownLabel(deadlineAtMs: request.deadlineAtMs, nowMs: nowMs)
        super.init(frame: .zero)
        appearance = NSAppearance(named: .darkAqua)
        wantsLayer = true
        layer?.backgroundColor = ApprovalPalette.cardBackground.cgColor
        layer?.borderColor = ApprovalPalette.warning.withAlphaComponent(0.6).cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 6

        textLabel.font = .systemFont(ofSize: 12, weight: .medium)
        textLabel.textColor = ApprovalPalette.commandText
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.maximumNumberOfLines = 1
        textLabel.cell?.truncatesLastVisibleLine = true
        textLabel.stringValue = Self.line(request: request, model: model, agentName: agentName)
        textLabel.toolTip = textLabel.stringValue
        textLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        expandButton.identifier = NSUserInterfaceItemIdentifier("expand")
        expandButton.target = self
        expandButton.action = #selector(expandPressed)
        expandButton.isBordered = false
        expandButton.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Expand")
        expandButton.imagePosition = .imageOnly
        expandButton.contentTintColor = ApprovalPalette.mutedText
        expandButton.setAccessibilityLabel("Expand the approval card")
        expandButton.toolTip = "Expand"

        for v in [textLabel, countdown.label, expandButton] {
            v.translatesAutoresizingMaskIntoConstraints = true
            addSubview(v)
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(textLabel.stringValue)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { countdown.stop() }

    /// `⚠ Cody needs approval · Bash · rm -rf build/ …`: the first command as shown (invisible
    /// characters as tokens), with an ellipsis when there is more than that.
    static func line(request: ApprovalRequestWire, model: ApprovalDisplayModel, agentName: String) -> String {
        var line = "⚠ \(agentName) needs approval · \(request.displayName)"
        let summary = model.summary
        if !summary.isEmpty {
            line += " · \(summary)"
            if model.shownText != summary { line += " …" }
        }
        return line
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { countdown.stop() } else { countdown.start() }
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 8
        let chevron = Self.chevronWidth
        let countdownWidth = ApprovalCountdownLabel.width
        expandButton.frame = NSRect(x: bounds.width - pad - chevron, y: (bounds.height - 18) / 2, width: chevron, height: 18)
        countdown.label.frame = NSRect(x: expandButton.frame.minX - 4 - countdownWidth, y: (bounds.height - 16) / 2,
                                       width: countdownWidth, height: 16)
        textLabel.frame = NSRect(x: pad, y: (bounds.height - 16) / 2,
                                 width: max(40, countdown.label.frame.minX - 8 - pad), height: 16)
    }

    @objc private func expandPressed() { onExpand?() }
}
