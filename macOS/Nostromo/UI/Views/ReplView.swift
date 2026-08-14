import AppKit
import Combine

// MARK: - ReplView

/// Chat-style REPL pane backed by a ChatSession (Claude Code JSON streaming).
///
/// Layout: scrolling turn history (top) + input bar (bottom).
/// Turn views accumulate live blocks as Claude streams output.
/// ## Virtualization
///
/// The transcript's document view is a plain, frame-positioned `NSView`, not an
/// `NSStackView`, and only the turns near the viewport exist as views at all.
///
/// Auto Layout's engine is per-window, so its cost scales with the number of
/// *constrained* views present. An `NSStackView` chains all N arranged subviews
/// into one system and each turn's internal subgraph stays resident forever, so
/// one scroll view accumulated every constraint the session had ever produced
/// and re-solved it on every layout pass. Here each materialized turn is an
/// Auto Layout **island**: positioned by `frame`, holding exactly one
/// self-contained width constraint, with no constraint of any kind linking it to
/// the document view or to its siblings. Evicting one removes its whole subtree
/// from the engine.
///
/// `TurnListVirtualizer` owns the geometry — where every turn sits, which ones
/// intersect the viewport, and the anchor that keeps the operator's reading
/// position still while heights are corrected underneath them.
class ReplView: NSView {

    private let session:    ChatSession
    private let scrollView = NSScrollView()
    private let documentView = TranscriptDocumentView()
    private let inputBar   = ReplInputBar()

    private var inputBarHeightConstraint: NSLayoutConstraint!
    private let quickActions: [QuickAction]
    private var quickActionStrip: QuickActionStripView?
    private let contextMeter = ContextMeterView()

    /// Geometry for *every* turn; views for only a window of them.
    private let virtualizer = TurnListVirtualizer()
    /// The materialized window — never larger than
    /// `TurnListVirtualizer.maxMaterialized`.
    private var turnViews: [UUID: NSView] = [:]
    /// Turns whose content changed since they were last measured.
    private var pendingRemeasure: Set<UUID> = []
    /// What the operator has done to each turn — answered cards, expanded tool
    /// results — held here because turn views no longer survive long enough to
    /// hold it themselves. See `TurnInteractionStore`.
    private let interactions = TurnInteractionStore()
    /// At most one materialization pass is ever in flight. Materializing from
    /// inside a layout or scroll callback recurses; this is the same coalescing
    /// guard the old scroll path used, widened to cover the whole pass.
    private var passPending = false
    /// True for the duration of a pass, so the frame and scroll changes it makes
    /// cannot schedule another one. See `schedulePass`.
    private var isMaterializing = false
    /// Set when a *content* change asked for a pass. Cleared as a pass begins,
    /// so a change that lands while one is running still gets rendered — the
    /// `isMaterializing` guard suppresses self-inflicted requests, and dropping
    /// a real update alongside them would be a very quiet rendering bug.
    private var contentDirty = false
    /// Pane width the geometry was last computed for.
    private var laidOutWidth: CGFloat = 0
    private var cancellables = Set<AnyCancellable>()

    /// True while the transcript should auto-scroll to the newest content.
    /// Cleared when the user scrolls up to read history, so a background
    /// stream of blocks (tool calls, Perri's own chatter, etc.) doesn't yank
    /// the view back to the bottom out from under them. Set again once they
    /// scroll back down, or when they send a message themselves.
    private var isPinnedToBottom = true

    init(tag: String, agentName: String? = nil, displayName: String? = nil,
         workingDirectory: String? = nil, quickActions: [QuickAction] = []) {
        self.quickActions = quickActions
        // Use the shared registry so multiple windows showing the same tag
        // observe the same session and stay in sync (mirrored).
        session = AppStore.shared.session(for: tag, agentName: agentName, displayName: displayName, workingDirectory: workingDirectory)
        super.init(frame: .zero)
        setup()
        TranscriptDiagnostics.register(self)
        AppStore.shared.registerTranscriptPane(self)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Setup

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = Theme.bg.cgColor

        // Top border (visual separator from HUD above)
        let topBorder = NSView()
        topBorder.wantsLayer = true
        topBorder.layer?.backgroundColor = Theme.borderInactive.cgColor
        topBorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(topBorder)
        NSLayoutConstraint.activate([
            topBorder.topAnchor.constraint(equalTo: topAnchor),
            topBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            topBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            topBorder.heightAnchor.constraint(equalToConstant: 1),
        ])

        // Thin toolbar strip: "new session" button on the right
        let toolbar = NSView()
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor(white: 0.07, alpha: 1).cgColor
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toolbar)

        let newSessionBtn = NSButton()
        newSessionBtn.title            = "⌧ New session"
        newSessionBtn.font             = .systemFont(ofSize: 9)
        newSessionBtn.isBordered       = false
        newSessionBtn.contentTintColor = Theme.fgMuted
        newSessionBtn.target           = self
        newSessionBtn.action           = #selector(newSessionTapped)
        newSessionBtn.translatesAutoresizingMaskIntoConstraints = false
        toolbar.addSubview(newSessionBtn)

        let toolbarBottomBorder = NSView()
        toolbarBottomBorder.wantsLayer = true
        toolbarBottomBorder.layer?.backgroundColor = Theme.borderInactive.cgColor
        toolbarBottomBorder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(toolbarBottomBorder)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topBorder.bottomAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 22),
            newSessionBtn.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -8),
            newSessionBtn.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            toolbarBottomBorder.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            toolbarBottomBorder.leadingAnchor.constraint(equalTo: leadingAnchor),
            toolbarBottomBorder.trailingAnchor.constraint(equalTo: trailingAnchor),
            toolbarBottomBorder.heightAnchor.constraint(equalToConstant: 1),
        ])

        // Scroll view with flipped clip — content anchors to top.
        // Don't set drawsBackground on the clip view directly — per NSClipView docs,
        // doing so sets copiesOnScroll=false causing scroll trails. Set it on scrollView instead.
        let clip = ReplClipView()
        scrollView.contentView          = clip
        scrollView.drawsBackground      = false
        scrollView.hasVerticalScroller  = true
        scrollView.hasHorizontalScroller = false   // forces doc view to match scroll view width
        scrollView.autohidesScrollers   = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        // Live-scroll notifications only fire for user-driven trackpad/wheel
        // scrolling, not our own programmatic scrollToBottom() calls — exactly
        // the signal needed to tell "user is reading history" apart from
        // "we just auto-scrolled". Re-checked on every live-scroll tick so it
        // tracks drags back down to the bottom too.
        NotificationCenter.default.addObserver(
            self, selector: #selector(liveScrollDidChange),
            name: NSScrollView.didLiveScrollNotification, object: scrollView)

        // Programmatic scrolls (scroller drags, scrollToBottom, Home/End) do not
        // post live-scroll notifications, so the materialization pass would miss
        // them and the operator would drag into a blank region.
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipBoundsDidChange),
            name: NSView.boundsDidChangeNotification, object: clip)

        // Scripted scroll for the acceptance run — see TranscriptLoadHarness.
        NotificationCenter.default.addObserver(
            self, selector: #selector(runScriptedScrollRoundTrip),
            name: .transcriptLoadHarnessScroll, object: nil)

        // Frame-positioned document view. No constraints — not to the clip view,
        // not between turns. Its size is set from the virtualizer's own height
        // cache, never read back from AppKit.
        documentView.translatesAutoresizingMaskIntoConstraints = true
        documentView.frame = NSRect(x: 0, y: 0, width: 400, height: 1)
        scrollView.documentView = documentView

        // Input bar — fixed at bottom
        inputBar.translatesAutoresizingMaskIntoConstraints = false
        inputBar.onSend = { [weak self] text, images in
            guard let self else { return }
            self.isPinnedToBottom = true
            self.session.send(text, images: images)
        }
        addSubview(inputBar)

        inputBarHeightConstraint = inputBar.heightAnchor.constraint(equalToConstant: ReplInputBar.minHeight)

        // Optional quick-action strip — sits between scroll view and input bar
        if !quickActions.isEmpty {
            let strip = QuickActionStripView(actions: quickActions) { [weak self] action in
                self?.runQuickAction(action)
            }
            strip.translatesAutoresizingMaskIntoConstraints = false
            addSubview(strip)
            quickActionStrip = strip
        }

        // Context meter — 2px stripe on the border above the input bar.
        contextMeter.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contextMeter)

        // Scroll view's bottom connects to the strip (if present) or the meter.
        let scrollBottomTarget = quickActionStrip?.topAnchor ?? contextMeter.topAnchor

        var constraints: [NSLayoutConstraint] = [
            inputBar.bottomAnchor.constraint(equalTo: bottomAnchor),
            inputBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            inputBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            inputBarHeightConstraint,

            contextMeter.bottomAnchor.constraint(equalTo: inputBar.topAnchor),
            contextMeter.leadingAnchor.constraint(equalTo: leadingAnchor),
            contextMeter.trailingAnchor.constraint(equalTo: trailingAnchor),
            contextMeter.heightAnchor.constraint(equalToConstant: 2),

            scrollView.topAnchor.constraint(equalTo: toolbarBottomBorder.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: scrollBottomTarget),
        ]

        if let strip = quickActionStrip {
            constraints += [
                strip.leadingAnchor.constraint(equalTo: leadingAnchor),
                strip.trailingAnchor.constraint(equalTo: trailingAnchor),
                strip.bottomAnchor.constraint(equalTo: contextMeter.topAnchor),
                strip.heightAnchor.constraint(equalToConstant: 40),
            ]
        }

        NSLayoutConstraint.activate(constraints)

        inputBar.onHeightChange = { [weak self] ideal in
            guard let self else { return }
            // Cap at 1/3 of the pane's current height (fallback to 200 if not yet laid out).
            let cap = self.bounds.height > 0 ? self.bounds.height / 3 : 200
            let clamped = max(ReplInputBar.minHeight, min(ideal, cap))
            guard abs(self.inputBarHeightConstraint.constant - clamped) > 0.5 else { return }
            self.inputBarHeightConstraint.constant = clamped
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration     = 0.08
                ctx.allowsImplicitAnimation = true
                self.layoutSubtreeIfNeeded()
            }
        }

        // Combine.
        //
        // Note this subscribes to `session.changes`, NOT `session.$turns`.
        // `@Published` fires on every block append and the old handler responded
        // by walking the entire turn array, so the cost of painting one streamed
        // token rose linearly with session length. Adding a `$turns` subscriber
        // anywhere would reintroduce that.
        session.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in self?.apply(change) }
            .store(in: &cancellables)

        session.$isRunning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] r in self?.inputBar.setRunning(r) }
            .store(in: &cancellables)

        session.$pendingCount
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in self?.inputBar.setPendingCount(count) }
            .store(in: &cancellables)

        session.$contextFraction
            .receive(on: DispatchQueue.main)
            .sink { [weak self] fraction in self?.contextMeter.fraction = fraction }
            .store(in: &cancellables)
    }

    // MARK: Turn management

    /// Width available to a turn view. Read from the clip view's bounds, which
    /// is frame-driven by the scroll view's `tile()` and so is never dirty.
    private var contentWidth: CGFloat {
        max(scrollView.contentView.bounds.width, 1)
    }

    private func apply(_ change: TurnChange) {
        let turns = session.turns
        switch change {
        case .cleared:
            releaseAllTurnViews()
            // Nothing in `turns` survives, so nothing recorded against them
            // should either. This is half the bound that stops the interaction
            // store becoming the leak this work exists to remove.
            interactions.removeAll()
            virtualizer.reset(turns: turns, width: contentWidth)

        case .spliced(let from):
            // Releasing the views from `from` onward is not optional. The
            // reconciler deliberately carries the OLD id onto the snapshot's
            // version of each overlapping turn, so those turns have new content
            // under an id the materialized window still recognises: eviction
            // keeps them (their ids are wanted) and materialization skips them
            // (a view already exists). A turn interrupted mid-stream would stay
            // frozen at whatever blocks arrived before the disconnect —
            // permanently, and with nothing saying so — while the model held the
            // complete version.
            for turn in turns[min(from, turns.count)...] {
                turnViews.removeValue(forKey: turn.id)?.removeFromSuperview()
                pendingRemeasure.remove(turn.id)
                session.payloadStore.unpin(turn.id)
            }
            // The other half of the bound. A splice is the one event that can
            // remove turns from the list, and the retention cap reports itself as
            // `.spliced(replacedFrom: 0)` — so pruning here also covers dropped
            // history. Deliberately not done on every materialization pass: that
            // would put an O(turns) walk on the hot path, and between splices
            // growth is bounded by the turns a human actually interacted with.
            interactions.prune(keeping: Set(turns.map(\.id)))
            virtualizer.splice(turns: turns, from: from)

        case .appended(let index):
            guard index < turns.count else { return }
            virtualizer.append(turns[index])

        case .updatedBlocks(let index, _):
            guard index < turns.count else { return }
            let turn = turns[index]
            virtualizer.refresh(turn, at: index)
            // A streaming turn is materialized by definition, so append only the
            // blocks that are new rather than rebuilding its subtree.
            if let view = turnViews[turn.id] as? ChatTurnView {
                view.update(turn: turn)
                pendingRemeasure.insert(turn.id)
            }
        }
        // Distinguished from a scroll- or frame-driven request: a content change
        // must never be dropped, whereas a bounds notification the pass caused
        // itself must be.
        contentDirty = true
        schedulePass()
    }

    /// Queue a materialization pass. Never runs one synchronously: materializing
    /// from inside `layout()` or a scroll callback re-enters layout.
    ///
    /// The `isMaterializing` guard closes a feedback loop that is easy to miss
    /// and total when you hit it: the pass sets the document view's frame and
    /// scrolls the clip view, both of which post `boundsDidChangeNotification`
    /// synchronously, whose handler schedules another pass. Measured on the load
    /// harness, that saturated the run loop and throughput collapsed to about
    /// one turn every five seconds.
    private func schedulePass() {
        guard !passPending, !isMaterializing else { return }
        passPending = true
        DispatchQueue.main.async { [weak self] in
            self?.passPending = false
            self?.materialize()
        }
    }

    /// Reconcile the materialized views with the viewport, in five steps that
    /// must happen in this order.
    private func materialize() {
        let turns = session.turns
        guard contentWidth > 1, !isMaterializing else { return }
        isMaterializing = true
        contentDirty = false
        defer {
            isMaterializing = false
            if contentDirty { schedulePass() }
        }

        guard !turns.isEmpty else {
            releaseAllTurnViews()
            documentView.setFrameSize(NSSize(width: contentWidth,
                                             height: max(1, scrollView.contentView.bounds.height)))
            return
        }

        let viewport = scrollView.contentView.bounds
        // 1. Name where the operator is reading, BEFORE any height changes.
        let anchor = isPinnedToBottom ? nil : virtualizer.captureAnchor(viewportTop: viewport.minY)

        // 1b. Re-sync geometry to the turn array this pass is actually going to
        //     index, before asking it for a window.
        //
        //     `virtualizer.count` describes `session.turns` as of the last
        //     *delivered* change event, and `session.changes` is
        //     `receive(on: .main)` — one async hop minimum — so `session.turns` is
        //     always momentarily ahead of the geometry. Meanwhile scroll, clip
        //     bounds, intrinsic-height and scripted-scroll callbacks all schedule
        //     passes that never go through `apply(_:)` at all.
        //
        //     A pass landing in that gap indexed `turns` with a window sized from
        //     a stale `count`: **past the end** when the list shrank — the
        //     retention cap's `removeSubrange`, or a reconnect installing a
        //     shorter snapshot, both of which mutate `turns` synchronously and
        //     deliver their `.spliced` event behind the already-queued pass — and
        //     at wrong offsets when it grew. The load harness drives the scripted
        //     scroll round trip on a 0.05 s timer while turns arrive, so this is
        //     reachable exactly when the report is being read.
        //
        //     `splice(turns:from: 0)`, not `reset`: splice re-estimates but calls
        //     `adoptMeasuredHeights`, keeping every measured height, where `reset`
        //     clears the cache wholesale. The anchor captured above names a content
        //     key, so it survives the re-sync and still re-resolves the reading
        //     position in step 5. The `count` checks in `layout()` and
        //     `viewDidMoveToWindow()` are now redundant but harmless; this is the
        //     authoritative one, because it sits at the point of use.
        if virtualizer.count != turns.count {
            virtualizer.splice(turns: turns, from: 0)
        }
        let window = virtualizer.visibleWindow(viewport: viewport)
        assert(window.upperBound <= turns.count,
               "visibleWindow \(window) exceeds \(turns.count) turns — geometry is out of sync")

        // 2. Evict. Removing the subview releases the whole subtree and every
        //    constraint in it — recycling has to actually release, not merely
        //    stop adding.
        let wanted = Set(turns[window].map { $0.id })
        for (id, view) in turnViews where !wanted.contains(id) {
            view.removeFromSuperview()
            turnViews.removeValue(forKey: id)
            pendingRemeasure.remove(id)
            session.payloadStore.unpin(id)
        }

        // 3. Materialize what is missing and correct its estimated height to the
        //    real measured one.
        for i in window {
            let turn = turns[i]
            if turnViews[turn.id] == nil {
                let view = makeTurnView(for: turn)
                turnViews[turn.id] = view
                measure(view, at: i, isComplete: turn.isComplete)   // detached — see `measure`
                documentView.addSubview(view)
            } else if pendingRemeasure.contains(turn.id) {
                measure(turnViews[turn.id]!, at: i, isComplete: turn.isComplete)
            }
            pendingRemeasure.remove(turn.id)
        }

        // 4. Position, and size the document from the virtualizer's own cache —
        //    never by reading `documentView.frame`, which forces a synchronous
        //    layout pass on a dirty view.
        for i in window {
            turnViews[turns[i].id]?.setFrameOrigin(NSPoint(x: 0, y: virtualizer.offset(of: i)))
        }
        documentView.setFrameSize(NSSize(width: contentWidth,
                                         height: max(virtualizer.documentHeight, viewport.height)))

        // 5. Put the reading position back, or follow the newest content.
        if isPinnedToBottom {
            scrollToBottom()
        } else if let anchor {
            let top = virtualizer.restoredTop(for: anchor)
            if abs(top - viewport.minY) > 0.5 {
                scrollView.contentView.scroll(NSPoint(x: 0, y: top))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
    }

    /// Build a turn view, hydrating its payload first if it has gone cold.
    private func makeTurnView(for turn: ChatTurn) -> NSView {
        if let marker = turn.marker {
            return MarkerTurnView(marker: marker)
        }

        // Decompression measures ~0.06 ms for a 36 KB turn, so a full window is
        // a few milliseconds — inside one layout pass, and roughly eighty times
        // under the 250 ms budget. A turn that cannot be recovered says so
        // rather than rendering as an empty exchange.
        let hydrated: ChatTurn
        let contentAvailable: Bool
        switch session.hydrated(turn) {
        case .full(let t):        hydrated = t; contentAvailable = true
        case .unavailable(let t): hydrated = t; contentAvailable = false
        }
        session.payloadStore.pin(turn.id)

        let view = ChatTurnView(turn: hydrated, contentAvailable: contentAvailable,
                                interaction: interactions.state(for: turn.id))
        view.onSend = { [weak self] text in
            guard let self else { return }
            self.isPinnedToBottom = true
            self.session.send(text)
        }
        // An answered question card must come back answered. Rebuilt armed, it
        // would take one stray click to send a second message into a live agent
        // session — and eviction plus any width change rebuilds it routinely.
        view.onAnsweredOption = { [weak self] blockIndex, optionIndex in
            self?.interactions.recordAnswer(turn: turn.id, block: blockIndex, option: optionIndex)
        }
        // Expansion restore also keeps geometry and view agreeing: the height
        // cache keys measured heights by content, which is invariant across
        // expansion, so a re-collapsed tool result would leave the virtualizer
        // holding the expanded height.
        view.onBlockExpansion = { [weak self] blockIndex, isExpanded in
            self?.interactions.setExpanded(turn: turn.id, block: blockIndex, isExpanded)
        }
        // Expanding a tool result changes the turn's height, so the geometry has
        // to be told rather than left to discover it.
        view.onIntrinsicHeightChange = { [weak self] in
            guard let self else { return }
            self.pendingRemeasure.insert(turn.id)
            self.schedulePass()
        }
        return view
    }

    /// Measure a materialized turn at the current pane width and hand the real
    /// height to the virtualizer, replacing its estimate.
    ///
    /// The view carries exactly one constraint of its own — its width — which is
    /// what makes `fittingSize.height` well defined while it is still an island.
    private func measure(_ view: NSView, at index: Int, isComplete: Bool) {
        // Measured while **detached**, and that is not incidental.
        //
        // `translatesAutoresizingMaskIntoConstraints = true` makes AppKit install
        // constraints pinning the view's size to its frame the moment it has a
        // superview. `fittingSize` then just hands back the frame it already has:
        // a newly-created view measures as its zero frame (and conflicts with its
        // own width constraint while doing so), and a streaming turn re-measured
        // in place keeps reporting the height it had before the block arrived, so
        // the document silently stops growing.
        //
        // Detached, the only constraints it holds are its own width plus its
        // internal layout — which is exactly the question being asked.
        let superview = view.superview
        superview.map { _ in view.removeFromSuperview() }

        (view as? TurnIsland)?.setIslandWidth(contentWidth)
        view.layoutSubtreeIfNeeded()
        let height = max(view.fittingSize.height, TurnHeightEstimator.minimumTurnHeight)
        view.setFrameSize(NSSize(width: contentWidth, height: height))
        virtualizer.recordMeasured(height, at: index, isComplete: isComplete)

        superview?.addSubview(view)
    }

    private func releaseAllTurnViews() {
        // Unpinning matters as much as removing. `TurnPayloadStore` refuses to
        // compact a pinned turn, so a release that left the pins behind would
        // make `shedMaterializedViews()` structurally unable to compact the very
        // turns it just released — and the pinned set would grow on every window
        // resize until compaction was defeated entirely. Backwards, for a memory
        // fix.
        for (id, view) in turnViews {
            view.removeFromSuperview()
            session.payloadStore.unpin(id)
        }
        turnViews.removeAll()
        pendingRemeasure.removeAll()
    }

    /// Release every materialized view and re-materialize only what the viewport
    /// needs. Called by `MemoryWatchdog` on the shed path.
    ///
    /// `completion` fires once the session's compaction has landed, so the
    /// watchdog can measure memory that is genuinely free rather than memory it
    /// has merely asked for.
    func shedMaterializedViews(completion: @escaping () -> Void = {}) {
        releaseAllTurnViews()
        session.shedRetainedContent { [weak self] in
            self?.schedulePass()
            completion()
        }
    }

    private func scrollToBottom() {
        // Scroll to an arbitrarily large Y — AppKit clamps to the actual maximum.
        // Avoids accessing documentView.frame: reading `.frame` on a dirty NSView
        // triggers a synchronous layout pass.
        scrollView.contentView.scroll(NSPoint(x: 0, y: CGFloat.greatestFiniteMagnitude))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Re-pin to the bottom — call whenever the user takes an action that
    /// should bring the newest content into view (sending a message, an
    /// answer, a quick action).
    private func pinToBottomAndScroll() {
        isPinnedToBottom = true
        scrollToBottom()
    }

    @objc private func liveScrollDidChange() {
        updatePinnedState()
        schedulePass()
    }

    @objc private func clipBoundsDidChange() {
        // Scroller drags, Home/End and `scrollToBottom()` move the clip view
        // without posting a live-scroll notification — which is the entire reason
        // this observer exists. Updating the pass but not the pinned state meant
        // dragging up to read history left `isPinnedToBottom == true`, and the
        // very pass the drag scheduled took the operator straight back to the
        // bottom (`materialize()`, step 5).
        //
        // A bounds change observed while a pass is running was caused by that
        // pass — the notification is delivered synchronously from inside its own
        // scroll and frame calls — so it must not be read as operator intent.
        guard !isMaterializing else { return }
        updatePinnedState()
        schedulePass()
    }

    /// Scroll bottom → top → bottom, one viewport at a time, so the acceptance
    /// script can check that recycling actually releases (memory returns to
    /// within 50 MB of where it started) without driving UI automation.
    @objc private func runScriptedScrollRoundTrip() {
        let step = max(scrollView.contentView.bounds.height, 1)
        var y = virtualizer.documentHeight
        var goingUp = true
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            if goingUp {
                y -= step
                if y <= 0 { y = 0; goingUp = false }
            } else {
                y += step
                if y >= self.virtualizer.documentHeight {
                    self.isPinnedToBottom = true
                    self.schedulePass()
                    timer.invalidate()
                    return
                }
            }
            self.isPinnedToBottom = false
            self.scrollView.contentView.scroll(NSPoint(x: 0, y: y))
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updatePinnedState() {
        let visibleMaxY = scrollView.contentView.bounds.maxY
        // Within a small threshold of the true bottom counts as "pinned" —
        // demanding an exact match would fight sub-pixel rounding. Compares
        // against the virtualizer's cached height rather than the document
        // view's frame, for the reason in `scrollToBottom`.
        isPinnedToBottom = virtualizer.documentHeight - visibleMaxY < 40
    }

    override func layout() {
        super.layout()
        // A width change invalidates every estimate and every measurement, since
        // both were taken at the old width. Re-estimating five thousand turns is
        // a few million float ops — which is what keeps a resize interactive.
        let width = contentWidth
        guard width > 1, abs(width - laidOutWidth) > 0.5 else { return }
        laidOutWidth = width
        if virtualizer.count == session.turns.count {
            virtualizer.invalidateWidth(width, turns: session.turns)
        } else {
            virtualizer.reset(turns: session.turns, width: width)
        }
        releaseAllTurnViews()   // every measurement was taken at the old width
        schedulePass()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self.inputBar.textView)
        }
        // A pane rebuild reuses this instance (see DynamicFocusView), so scroll
        // position and pinned state survive it. A fresh instance re-syncs here.
        if window != nil, virtualizer.count != session.turns.count {
            virtualizer.reset(turns: session.turns, width: contentWidth)
            schedulePass()
        }
    }

    @objc private func newSessionTapped() {
        // Confirm before wiping history
        let alert = NSAlert()
        alert.messageText     = "Start new session?"
        alert.informativeText = "This clears the local display and disconnects from the current Claude session. Claude's memory of this conversation will be lost."
        alert.alertStyle      = .warning
        alert.addButton(withTitle: "New Session")
        alert.addButton(withTitle: "Cancel")
        // Present as a sheet on our own window rather than alert.runModal().
        // A free-floating modal alert has no window association, so it can end
        // up stranded on another Space/display with no visible way to dismiss
        // it — which blocks the whole app's main thread indefinitely (it looks
        // exactly like a hang). A sheet is always anchored to this window and
        // resolves asynchronously, so it can't wander off or block the app.
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            // `newSession()` emits `.cleared`, which releases every turn view and
            // resets the geometry.
            self.session.newSession()
        }
    }

    private func runQuickAction(_ action: QuickAction) {
        if action.clearFirst {
            // Mirror newSessionTapped's local-history clear so the transcript
            // empties immediately, then start a fresh daemon session.
            // No confirmation dialog — quick actions are intentional one-tap affordances.
            session.newSession()
        }
        let prompt = action.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty {
            isPinnedToBottom = true
            session.send(prompt)
        }
    }
}

// MARK: - Diagnostics

extension ReplView: TranscriptDiagnostics.Reporting {
    var diagnosticsTag: String          { session.tag }
    var retainedTurnCount: Int          { session.turns.count }
    /// Constant in session length, and never above
    /// `TurnListVirtualizer.maxMaterialized` — the criterion this whole change
    /// turns on.
    var materializedViewCount: Int      { turnViews.count }
    var hotPayloadTurnCount: Int        { session.hotPayloadTurnCount }
    var compressedPayloadBytes: Int     { session.payloadStore.stats.compressedBytes }
    var estimatedDocumentHeight: Double { Double(virtualizer.documentHeight) }
    var transcriptClearCount: Int       { session.transcriptClears }
}

// MARK: - ReplClipView

private class ReplClipView: NSClipView {
    override var isFlipped: Bool { true }
}

// MARK: - TranscriptDocumentView

/// The scroll view's document view: a plain container whose height comes from
/// `TurnListVirtualizer` and whose children are positioned by frame.
///
/// Flipped so y grows downward and turn offsets are the virtualizer's own
/// coordinates with no conversion. Deliberately has no constraints and no
/// `layout()` of its own — a document view that participates in Auto Layout is
/// precisely what made the constraint graph scale with session length.
private class TranscriptDocumentView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
}

// MARK: - TurnIsland

/// A turn view that owns exactly one constraint of its own — its width — so it
/// can be measured with `fittingSize` before it is inserted anywhere, and can be
/// re-widened on a pane resize without ever being constrained to its container.
private protocol TurnIsland: NSView {
    func setIslandWidth(_ width: CGFloat)
}

// MARK: - MarkerTurnView

/// Renders the transcript's statements about history it cannot show.
///
/// The PRD is explicit that the one thing worse than losing scrollback is the
/// operator judging what an agent did from a transcript that quietly omitted
/// part of it. So these are plain, unmissable, and rendered in place.
private class MarkerTurnView: NSView, TurnIsland {

    private var widthConstraint: NSLayoutConstraint!

    init(marker: ChatTurn.Marker) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = true
        wantsLayer = true

        let text: String
        switch marker {
        case .gap:
            text = "⋯  Earlier turns may be missing here — this pane was disconnected for longer than the daemon keeps in its attach window."
        case .historyUnavailable:
            text = "⋯  Earlier history is no longer available in this pane. The full record remains on disk in the Claude session transcript."
        }

        let label = NSTextField(labelWithString: text)
        label.font                 = .systemFont(ofSize: 11)
        label.textColor            = Theme.fgMuted
        label.lineBreakMode        = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.alignment            = .center
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let rule = NSView()
        rule.wantsLayer = true
        rule.layer?.backgroundColor = Theme.borderInactive.withAlphaComponent(0.6).cgColor
        rule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rule)

        widthConstraint = widthAnchor.constraint(equalToConstant: 400)
        NSLayoutConstraint.activate([
            widthConstraint,
            label.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            rule.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 8),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            rule.heightAnchor.constraint(equalToConstant: 1),
            rule.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setIslandWidth(_ width: CGFloat) { widthConstraint.constant = width }
}

// MARK: - ReplInputBar

private class ReplInputBar: NSView, NSTextViewDelegate {

    var onSend:        ((String, [URL]) -> Void)?
    /// Fired whenever the text grows/shrinks; passes the ideal total bar height.
    var onHeightChange: ((CGFloat) -> Void)?

    static let minHeight: CGFloat = 46

    private var pendingImages: [URL] = []

    private let textScroll   = NSScrollView()
    let textView             = ChatTextView()
    private let placeholder  = NSTextField(labelWithString: "Message…")
    private let button       = NSButton()
    private let spinner      = NSProgressIndicator()
    /// Horizontal strip of image thumbnails shown above the text field when images are attached.
    private let imageTray    = NSStackView()

    override init(frame: NSRect) {
        super.init(frame: frame)

        wantsLayer = true
        layer?.backgroundColor = Theme.bgBar.cgColor

        // Top border
        let border = NSView()
        border.wantsLayer = true
        border.layer?.backgroundColor = Theme.borderInactive.cgColor
        border.translatesAutoresizingMaskIntoConstraints = false
        addSubview(border)
        NSLayoutConstraint.activate([
            border.topAnchor.constraint(equalTo: topAnchor),
            border.leadingAnchor.constraint(equalTo: leadingAnchor),
            border.trailingAnchor.constraint(equalTo: trailingAnchor),
            border.heightAnchor.constraint(equalToConstant: 1),
        ])

        // NSTextView — multi-line, grows with content
        textView.isRichText              = false
        textView.font                    = Theme.firaCode(size: 13)
        textView.textColor               = Theme.fg
        // Enable all ligatures so Fira Code's OpenType features (→ => != etc.) render.
        textView.typingAttributes[.ligature] = 2
        textView.backgroundColor         = NSColor(white: 0.14, alpha: 1)
        textView.drawsBackground         = true
        textView.isEditable              = true
        textView.isSelectable            = true
        textView.allowsUndo              = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable   = true
        textView.textContainerInset      = NSSize(width: 4, height: 6)
        textView.textContainer?.widthTracksTextView  = true
        textView.textContainer?.heightTracksTextView = false
        textView.appearance = NSAppearance(named: .darkAqua)
        textView.delegate   = self
        textView.onSubmit   = { [weak self] in self?.submitAction() }

        // Scroll wrapper — no border; we style the layer instead
        textScroll.documentView          = textView
        textScroll.borderType            = .noBorder
        textScroll.drawsBackground       = false
        textScroll.hasVerticalScroller   = true
        textScroll.autohidesScrollers    = true
        textScroll.hasHorizontalScroller = false
        textScroll.wantsLayer            = true
        textScroll.layer?.backgroundColor = NSColor(white: 0.14, alpha: 1).cgColor
        textScroll.layer?.cornerRadius   = 6
        textScroll.layer?.borderWidth    = 0.5
        textScroll.layer?.borderColor    = NSColor(white: 0.35, alpha: 1).cgColor
        textScroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textScroll)

        // Placeholder label — visible when text is empty
        placeholder.font      = Theme.firaCode(size: 13)
        placeholder.textColor = Theme.fgMuted
        placeholder.isEnabled = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        textScroll.addSubview(placeholder)

        // Send button
        button.bezelStyle = .inline
        button.isBordered = false
        button.wantsLayer = true
        button.layer?.backgroundColor = Theme.cornflower.withAlphaComponent(0.25).cgColor
        button.layer?.cornerRadius    = 5
        let btnAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: Theme.fg,
        ]
        button.attributedTitle = NSAttributedString(string: "Send", attributes: btnAttrs)
        button.target = self
        button.action = #selector(sendButtonAction)
        button.translatesAutoresizingMaskIntoConstraints = false
        addSubview(button)

        // Spinner
        spinner.style                   = .spinning
        spinner.controlSize             = .small
        spinner.isDisplayedWhenStopped  = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)

        // Image tray — hidden until images are dropped
        imageTray.orientation    = .horizontal
        imageTray.spacing        = 6
        imageTray.alignment      = .centerY
        imageTray.isHidden       = true
        imageTray.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageTray)

        NSLayoutConstraint.activate([
            // Image tray sits above the text scroll view when visible
            imageTray.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            imageTray.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -8),
            imageTray.topAnchor.constraint(equalTo: border.bottomAnchor, constant: 6),
            imageTray.heightAnchor.constraint(equalToConstant: 48),

            textScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            textScroll.topAnchor.constraint(equalTo: border.bottomAnchor, constant: 9),
            textScroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
            textScroll.trailingAnchor.constraint(equalTo: button.leadingAnchor, constant: -8),

            // Placeholder anchored to the text inset area
            placeholder.leadingAnchor.constraint(equalTo: textScroll.leadingAnchor, constant: 4),
            placeholder.topAnchor.constraint(equalTo: textScroll.topAnchor, constant: 6),

            button.trailingAnchor.constraint(equalTo: spinner.leadingAnchor, constant: -8),
            button.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            button.widthAnchor.constraint(equalToConstant: 54),
            button.heightAnchor.constraint(equalToConstant: 26),

            spinner.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            spinner.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -15),
            spinner.widthAnchor.constraint(equalToConstant: 16),
            spinner.heightAnchor.constraint(equalToConstant: 16),
        ])

        // Register for image drag-and-drop
        registerForDraggedTypes([.fileURL, .tiff, .png])
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Actions

    @objc private func sendButtonAction() { submitAction() }

    private func submitAction() {
        var text         = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let imagesToSend = pendingImages
        // Allow send when images are present even with no text — synthesise a
        // description from filenames so Claude gets a non-empty message.
        if text.isEmpty && !imagesToSend.isEmpty {
            text = imagesToSend.map { "[\($0.lastPathComponent)]" }.joined(separator: " ")
        }
        guard !text.isEmpty else { return }
        textView.string  = ""
        pendingImages    = []
        placeholder.isHidden = false
        // Hiding the tray does not release its chips. Each one holds a decoded
        // image, and they stayed retained for the lifetime of the pane —
        // `removeImageChip` got this right and the send path did not.
        clearImageTray()
        onHeightChange?(Self.minHeight)
        onSend?(text, imagesToSend)
    }

    // MARK: State

    func setRunning(_ running: Bool) {
        button.alphaValue = running ? 0.5 : 1.0
        running ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
    }

    func setPendingCount(_ count: Int) {
        placeholder.stringValue = count > 0 ? "Message… (\(count) queued)" : "Message…"
    }

    // MARK: Drag-and-drop (images)

    private static let imageUTIs: Set<String> = ["public.image", "public.png", "public.jpeg",
                                                  "public.tiff", "public.gif", "public.heic",
                                                  "public.webp"]

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = imageURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return [] }
        layer?.borderWidth = 1
        layer?.borderColor = Theme.cornflower.withAlphaComponent(0.6).cgColor
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        layer?.borderWidth = 0
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = imageURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        layer?.borderWidth = 0
        urls.forEach { addImage($0) }
        return true
    }

    private func imageURLs(from pb: NSPasteboard) -> [URL] {
        guard let items = pb.readObjects(forClasses: [NSURL.self],
                                         options: [.urlReadingFileURLsOnly: true]) as? [URL]
        else { return [] }
        return items.filter { url in
            guard let uti = try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier
            else { return false }
            return Self.imageUTIs.contains(where: { UTTypeConformsTo(uti as CFString, $0 as CFString) })
        }
    }

    private func addImage(_ url: URL) {
        guard !pendingImages.contains(url) else { return }
        pendingImages.append(url)

        // Build a small thumbnail chip
        let chip = NSView()
        chip.wantsLayer  = true
        chip.layer?.cornerRadius = 4
        chip.layer?.backgroundColor = NSColor(white: 0.18, alpha: 1).cgColor
        chip.translatesAutoresizingMaskIntoConstraints = false

        let img = NSImageView()
        // Decoded to chip size, never to source size — see ThumbnailLoader.
        img.imageScaling = .scaleProportionallyUpOrDown
        let scale = window?.backingScaleFactor ?? 2
        ThumbnailLoader.load(url, scale: max(2, scale)) { [weak img] thumbnail in
            img?.image = thumbnail
        }
        img.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(img)

        let nameLabel = NSTextField(labelWithString: url.lastPathComponent + " (name only)")
        nameLabel.font          = .systemFont(ofSize: 9)
        nameLabel.textColor     = Theme.fgMuted
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(nameLabel)

        let removeBtn = NSButton()
        removeBtn.title     = "✕"
        removeBtn.font      = .systemFont(ofSize: 9)
        removeBtn.isBordered = false
        removeBtn.contentTintColor = Theme.fgMuted
        // Capture url directly in the action closure via a helper wrapper
        removeBtn.target    = self
        removeBtn.action    = #selector(removeImageChip(_:))
        // Store the URL via associated object so the selector can find it
        objc_setAssociatedObject(removeBtn, &ReplInputBar.urlKey, url, .OBJC_ASSOCIATION_RETAIN)
        removeBtn.translatesAutoresizingMaskIntoConstraints = false
        chip.addSubview(removeBtn)

        NSLayoutConstraint.activate([
            img.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 4),
            img.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            img.widthAnchor.constraint(equalToConstant: 36),
            img.heightAnchor.constraint(equalToConstant: 36),

            nameLabel.leadingAnchor.constraint(equalTo: img.trailingAnchor, constant: 4),
            nameLabel.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            nameLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 90),

            removeBtn.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 2),
            removeBtn.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -4),
            removeBtn.centerYAnchor.constraint(equalTo: chip.centerYAnchor),

            chip.heightAnchor.constraint(equalToConstant: 44),
        ])

        imageTray.addArrangedSubview(chip)
        imageTray.isHidden = false
        // Bump bar height for the tray
        onHeightChange?(idealBarHeight() + 54)
    }

    private static var urlKey = 0

    /// Tear the tray down to nothing. `NSStackView.removeArrangedSubview` only
    /// stops managing a view; releasing it needs `removeFromSuperview` too.
    private func clearImageTray() {
        for chip in imageTray.arrangedSubviews {
            imageTray.removeArrangedSubview(chip)
            chip.removeFromSuperview()
        }
        imageTray.isHidden = true
    }

    @objc private func removeImageChip(_ sender: NSButton) {
        guard let chip = sender.superview else { return }
        if let url = objc_getAssociatedObject(sender, &ReplInputBar.urlKey) as? URL {
            pendingImages.removeAll { $0 == url }
        }
        imageTray.removeArrangedSubview(chip)
        chip.removeFromSuperview()
        if pendingImages.isEmpty {
            imageTray.isHidden = true
            onHeightChange?(idealBarHeight())
        }
    }

    // MARK: NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        placeholder.isHidden = !textView.string.isEmpty
        onHeightChange?(idealBarHeight())
    }

    // MARK: Height calculation

    private func idealBarHeight() -> CGFloat {
        let insets  = textView.textContainerInset.height * 2
        let margins: CGFloat = 9 + 9 + 1

        // Use NSTextLayoutManager (macOS 12+) to avoid forcing NSLayoutManager
        // compatibility mode. Accessing textView.layoutManager on macOS 12+ downgrades
        // the text view to the legacy layout engine for its lifetime.
        if let tlm = textView.textLayoutManager {
            tlm.ensureLayout(for: tlm.documentRange)
            var maxY: CGFloat = 0
            tlm.enumerateTextLayoutFragments(
                from: tlm.documentRange.location,
                options: [.ensuresLayout, .ensuresExtraLineFragment]
            ) { frag in
                maxY = frag.layoutFragmentFrame.maxY
                return true
            }
            return max(Self.minHeight, ceil(maxY + insets + margins))
        }

        // Legacy fallback (pre-macOS 12 or if textLayoutManager is nil)
        guard let lm = textView.layoutManager, let tc = textView.textContainer
        else { return Self.minHeight }
        lm.ensureLayout(for: tc)
        let textH = lm.usedRect(for: tc).height
        return max(Self.minHeight, ceil(textH + insets + margins))
    }
}

// MARK: - ChatTurnView

private class ChatTurnView: NSView, TurnIsland {

    private let blocksStack   = NSStackView()
    private var renderedCount = 0
    private var widthConstraint: NSLayoutConstraint!
    /// False when this turn's payload was dropped past the retention cap. Its
    /// blocks say so rather than rendering as empty.
    private let contentAvailable: Bool

    /// Fired when a block changes its own height (a tool result expanding), so
    /// `ReplView` re-measures rather than leaving the geometry stale.
    var onIntrinsicHeightChange: (() -> Void)?

    /// Fired when the operator answers an `AskUserQuestion` card, so the choice
    /// can be recorded outside this view — which is destroyed on eviction and on
    /// every width change. See `TurnInteractionStore`.
    var onAnsweredOption: ((_ blockIndex: Int, _ optionIndex: Int) -> Void)?

    /// Fired when the operator expands or collapses a tool result. Distinct from
    /// `onIntrinsicHeightChange`, which is about geometry: this one is about
    /// persistence, so the state survives the view.
    var onBlockExpansion: ((_ blockIndex: Int, _ isExpanded: Bool) -> Void)?

    /// Everything the operator has already done to this turn, restored into the
    /// block views as they are built.
    private let interaction: TurnInteractionState

    func setIslandWidth(_ width: CGFloat) { widthConstraint.constant = width }

    /// Reply text injected by the confirm card — suppress its bubble so the card
    /// itself serves as the only visible acknowledgement of the user's choice.
    private static let confirmReplySentinel = "(This answers your question:"

    /// Called when the user answers an in-turn `AskUserQuestion` card.
    /// Wired by `ReplView` to `session.send(_:)`.
    var onSend: ((String) -> Void)?

    init(turn: ChatTurn, contentAvailable: Bool, interaction: TurnInteractionState) {
        self.contentAvailable = contentAvailable
        self.interaction      = interaction
        super.init(frame: .zero)
        // Positioned by frame inside the document view, with exactly one
        // constraint of its own — its width. Nothing ties it to its container or
        // to its siblings, so the constraint engine holds one independent
        // component per materialized turn instead of one graph spanning the
        // session, and evicting it removes that component entirely.
        translatesAutoresizingMaskIntoConstraints = true
        wantsLayer = true
        widthConstraint = widthAnchor.constraint(equalToConstant: 400)
        widthConstraint.isActive = true

        // Blocks container — AI response, left-aligned at 82% width.
        //
        // The width fractions and the stack spacing here are read back by
        // `TurnHeightEstimator`, which has to reproduce this layout arithmetically
        // to estimate a turn's height before it is built. They are referenced from
        // there rather than repeated, so a change to the layout cannot silently
        // desynchronise the estimator. The remaining calibration constants in that
        // file are *sums* of several constraint constants below (chrome, padding);
        // folding those together needs a real refactor of these views and is
        // deliberately not part of this change.
        blocksStack.orientation = .vertical
        blocksStack.spacing     = TurnHeightEstimator.blockSpacing
        blocksStack.alignment   = .width
        blocksStack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(blocksStack)

        // Suppress the bubble when the reply was injected by the confirm card — the
        // card's own chosen-state visuals already acknowledge the selection.
        let suppressBubble = turn.userInput.contains(Self.confirmReplySentinel)

        if suppressBubble {
            // Pin blocksStack directly to the top so there is no gap where the bubble
            // would have been.
            NSLayoutConstraint.activate([
                blocksStack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
                blocksStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
                blocksStack.widthAnchor.constraint(equalTo: widthAnchor,
                                                   multiplier: TurnHeightEstimator.blocksWidthFraction,
                                                   constant: -14),
                blocksStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            ])
        } else {
            // User bubble — trailing-pinned, width driven by intrinsicContentSize capped at 75%.
            // No spacer/NSStackView needed: trailing anchor right-aligns it, intrinsicContentSize
            // gives AutoLayout the natural width, and the ≤ constraint caps long messages.
            let bubble = UserBubbleView(text: turn.userInput)
            bubble.translatesAutoresizingMaskIntoConstraints = false
            addSubview(bubble)

            NSLayoutConstraint.activate([
                bubble.topAnchor.constraint(equalTo: topAnchor, constant: 12),
                bubble.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
                // Fixed 75 % width so AutoLayout never needs intrinsicContentSize — the
                // unconstrained single-line NSTextField width overflowed the right edge.
                bubble.widthAnchor.constraint(equalTo: widthAnchor,
                                              multiplier: TurnHeightEstimator.bubbleWidthFraction),

                blocksStack.topAnchor.constraint(equalTo: bubble.bottomAnchor, constant: 8),
                blocksStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
                blocksStack.widthAnchor.constraint(equalTo: widthAnchor,
                                                   multiplier: TurnHeightEstimator.blocksWidthFraction,
                                                   constant: -14),
                blocksStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            ])
        }

        // Every block of an unrecoverable turn is truncated — the user bubble
        // and the assistant's text as much as its tool results — so an answer
        // would otherwise stop mid-sentence with nothing to explain it. One
        // banner at the top of the turn covers all of them; the tool-result
        // disclosure adds its own line because that content is separately
        // expandable.
        if !contentAvailable {
            blocksStack.addArrangedSubview(Self.makeTruncationBanner())
        }
        renderNewBlocks(turn.blocks)
    }

    private static func makeTruncationBanner() -> NSView {
        let label = NSTextField(labelWithString:
            "⚠︎  Only the beginning of this turn is still held in this pane. "
            + "The full text remains in the Claude session transcript on disk.")
        label.font                 = .systemFont(ofSize: 10)
        label.textColor            = Theme.amber
        label.lineBreakMode        = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Called as the turn's blocks array grows during live streaming.
    func update(turn: ChatTurn) {
        let newBlocks = Array(turn.blocks.dropFirst(renderedCount))
        renderNewBlocks(newBlocks)
    }

    private func renderNewBlocks(_ blocks: [TurnBlock]) {
        for block in blocks {
            // `renderedCount` is already the index of the block being added, and
            // it keeps counting across streaming `update(turn:)` calls — so it is
            // the block index, and a second counter would only be a second thing
            // to get out of step with it.
            let v = makeBlockView(block, at: renderedCount)
            v.translatesAutoresizingMaskIntoConstraints = false
            blocksStack.addArrangedSubview(v)
            // Explicitly match width — NSStackView alignment=.width doesn't reliably
            // propagate width to custom views with no intrinsic size (e.g. TextBlockView)
            v.widthAnchor.constraint(equalTo: blocksStack.widthAnchor).isActive = true
            renderedCount += 1
        }
    }

    private func makeBlockView(_ block: TurnBlock, at index: Int) -> NSView {
        switch block {
        case .text(let t):           return TextBlockView(text: t)
        case .toolCall(let d):       return ToolCallView(data: d)
        case .toolResult(let d):
            let v = ToolResultView(data: d, contentAvailable: contentAvailable,
                                   startExpanded: interaction.expandedBlocks.contains(index))
            v.onExpansionChange = { [weak self] isExpanded in
                guard let self else { return }
                self.onBlockExpansion?(index, isExpanded)
                self.onIntrinsicHeightChange?()
            }
            return v
        case .resultSummary(let d):  return ResultChipView(data: d)
        case .errorMessage(let m):   return ErrorBlockView(message: m)
        case .askQuestion(let d):
            let v = AskQuestionView(data: d,
                                    answeredOptionIndex: interaction.answeredOptions[index])
            v.onAnswer = { [weak self] answer, optionIndex in
                guard let self else { return }
                // Record before sending. If the send path ever tears this view
                // down, the answer is already outside it.
                self.onAnsweredOption?(index, optionIndex)
                self.onSend?(answer)
            }
            return v
        }
    }
}

// MARK: - UserBubbleView

/// Right-floating chat bubble for user messages.
/// Overrides intrinsicContentSize so NSStackView (bubbleRow) can determine height.
private class UserBubbleView: NSView {

    private let label: NSTextField

    init(text: String) {
        label = NSTextField(labelWithString: text)
        label.font                 = .systemFont(ofSize: 13)
        label.textColor            = Theme.fg
        label.lineBreakMode        = .byWordWrapping
        label.maximumNumberOfLines = 0
        // Yield horizontally so the label wraps to the available width instead of
        // demanding its full single-line width (which would balloon the scroll view
        // and, ultimately, the whole window past the screen edge).
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false

        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.cornflower.withAlphaComponent(0.18).cgColor
        layer?.cornerRadius    = 12
        layer?.borderWidth     = 1
        layer?.borderColor     = Theme.cornflower.withAlphaComponent(0.35).cgColor

        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - TextBlockView

/// Renders text with markdown table detection. Tables become native grid views;
/// paragraphs stay as labels.
///
/// Uses explicit leading/trailing constraints (not NSStackView alignment) so
/// MarkdownTableView — which has no intrinsic content size — fills the full width.
private class TextBlockView: NSView {

    init(text: String) {
        super.init(frame: .zero)

        // Route to markdown cards if text has markdown content and no pipe table.
        // (Pipe tables use the existing MarkdownTableView path.)
        if !Self.hasPipeTable(text) && Self.hasMarkdown(text) {
            let segments = Self.markdownSegments(from: text)
            var prevAnchor: NSLayoutYAxisAnchor = topAnchor
            for (i, segment) in segments.enumerated() {
                let card = MarkdownCardView(markdown: segment)
                card.translatesAutoresizingMaskIntoConstraints = false
                addSubview(card)
                NSLayoutConstraint.activate([
                    card.topAnchor.constraint(equalTo: prevAnchor, constant: i == 0 ? 0 : 8),
                    card.leadingAnchor.constraint(equalTo: leadingAnchor),
                    card.trailingAnchor.constraint(equalTo: trailingAnchor),
                ])
                prevAnchor = card.bottomAnchor
            }
            if let last = subviews.last {
                last.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
            }
            return
        }

        let segments = Self.parseSegments(text)
        var prevAnchor: NSLayoutYAxisAnchor? = nil

        for segment in segments {
            let view: NSView
            switch segment {
            case .paragraph(let txt):
                let label = NSTextField(labelWithString: Self.stripMarkdown(txt))
                label.font                 = .systemFont(ofSize: 13)
                label.textColor            = Theme.fg
                label.lineBreakMode        = .byWordWrapping
                label.maximumNumberOfLines = 0
                label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                view = label
            case .table(let headers, let rows):
                view = MarkdownTableView(headers: headers, rows: rows)
            }

            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: trailingAnchor),
                view.topAnchor.constraint(equalTo: prevAnchor ?? topAnchor,
                                          constant: prevAnchor == nil ? 0 : 8),
            ])
            prevAnchor = view.bottomAnchor
        }

        // Close off the view's intrinsic height
        if let last = prevAnchor {
            last.constraint(equalTo: bottomAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Markdown detection & segmentation

    /// Returns true when the text contains enough markdown markers to warrant card rendering.
    private static func hasMarkdown(_ s: String) -> Bool {
        let lines = s.components(separatedBy: "\n")
        let lineMarker = lines.contains { line in
            line.hasPrefix("# ") || line.hasPrefix("## ") || line.hasPrefix("### ")
                || line.hasPrefix("- ") || line.hasPrefix("* ")
                || line.range(of: #"^\d+\.\s"#, options: .regularExpression) != nil
        }
        return lineMarker || s.contains("`") || s.contains("**") || s.contains("\n---")
    }

    /// Splits text on bare `---` separator lines into one or more markdown segments.
    private static func markdownSegments(from text: String) -> [String] {
        var segments: [String] = []
        var current: [String]  = []
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces) == "---" {
                let seg = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !seg.isEmpty { segments.append(seg) }
                current = []
            } else {
                current.append(line)
            }
        }
        let tail = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { segments.append(tail) }
        return segments
    }

    /// Returns true when the text contains a markdown pipe table (takes the existing path).
    private static func hasPipeTable(_ s: String) -> Bool {
        let lines = s.components(separatedBy: "\n")
        guard let headerIdx = lines.firstIndex(where: { $0.hasPrefix("|") }) else { return false }
        let nextIdx = lines.index(after: headerIdx)
        guard nextIdx < lines.endIndex else { return false }
        return lines[nextIdx].contains("|") && lines[nextIdx].contains("-")
    }

    // MARK: Segment model & parser

    private enum Segment {
        case paragraph(String)
        case table(headers: [String], rows: [[String]])
    }

    private static func parseSegments(_ text: String) -> [Segment] {
        let lines = text.components(separatedBy: "\n")
        var segments: [Segment] = []
        var pending: [String]   = []
        var i = 0

        while i < lines.count {
            let line = lines[i]
            let next = i + 1 < lines.count ? lines[i + 1] : ""

            // Markdown table: current line starts with |, next line is |---|
            if line.hasPrefix("|"), next.hasPrefix("|"), next.contains("---") {
                // Flush pending paragraph
                let txt = pending.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !txt.isEmpty { segments.append(.paragraph(txt)) }
                pending = []

                let headers = parseCells(line)
                i += 2  // skip header row + separator row
                var rows: [[String]] = []
                while i < lines.count && lines[i].hasPrefix("|") {
                    rows.append(parseCells(lines[i]))
                    i += 1
                }
                if !headers.isEmpty { segments.append(.table(headers: headers, rows: rows)) }
            } else {
                pending.append(line)
                i += 1
            }
        }

        let tail = pending.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { segments.append(.paragraph(tail)) }

        return segments
    }

    private static func parseCells(_ line: String) -> [String] {
        line.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { stripMarkdownLinks($0) }
    }

    /// Converts `[label](url)` → `label` so URLs don't blow up column widths.
    private static let linkRegex = try? NSRegularExpression(pattern: #"\[([^\]]*)\]\([^)]*\)"#)
    private static let boldRegex = try? NSRegularExpression(pattern: #"\*\*([^*]+)\*\*"#)
    private static let italRegex = try? NSRegularExpression(pattern: #"\*([^*]+)\*"#)

    private static func stripMarkdownLinks(_ text: String) -> String {
        guard text.contains("](") else { return text }
        let ns    = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return linkRegex?.stringByReplacingMatches(in: text, range: range, withTemplate: "$1") ?? text
    }

    /// Strip `**bold**`, `*italic*`, and `[text](url)` so they don't appear raw in paragraph text.
    static func stripMarkdown(_ text: String) -> String {
        var s = text
        for (regex, template) in [(boldRegex, "$1"), (italRegex, "$1"), (linkRegex, "$1")] {
            guard let rx = regex else { continue }
            let ns = s as NSString
            s = rx.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: template)
        }
        return s
    }
}

// MARK: - MarkdownTableView

/// Native grid renderer for markdown pipe tables.
///
/// Rows are pinned with explicit leading/trailing constraints (not NSStackView alignment)
/// so column widths are computed correctly from the table's actual width.
private class MarkdownTableView: NSView {

    init(headers: [String], rows: [[String]]) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth  = 1
        layer?.borderColor  = Theme.borderInactive.withAlphaComponent(0.5).cgColor

        let colCount = max(headers.count, rows.map { $0.count }.max() ?? 1)
        guard colCount > 0 else { return }

        let allRows: [[String]] = [headers] + rows
        var prevAnchor: NSLayoutYAxisAnchor? = nil

        for (rowIdx, rowData) in allRows.enumerated() {
            let isHeader   = rowIdx == 0
            let isLast     = rowIdx == allRows.count - 1
            let bgAlpha: CGFloat = isHeader ? 0.14 : (rowIdx % 2 == 0 ? 0.09 : 0.105)
            let rowHeight: CGFloat = isHeader ? 30 : 26

            let rowView = NSView()
            rowView.wantsLayer = true
            rowView.layer?.backgroundColor = NSColor(white: bgAlpha, alpha: 1).cgColor
            rowView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(rowView)

            // Pin row to full table width — this is what determines column widths
            NSLayoutConstraint.activate([
                rowView.leadingAnchor.constraint(equalTo: leadingAnchor),
                rowView.trailingAnchor.constraint(equalTo: trailingAnchor),
                rowView.topAnchor.constraint(equalTo: prevAnchor ?? topAnchor),
                rowView.heightAnchor.constraint(equalToConstant: rowHeight),
            ])
            prevAnchor = rowView.bottomAnchor

            // Build equal-width columns
            var labels: [NSTextField] = []
            for colIdx in 0..<colCount {
                let text  = colIdx < rowData.count ? rowData[colIdx] : ""
                let label = NSTextField(labelWithString: text)
                label.font                 = isHeader
                    ? .systemFont(ofSize: 11, weight: .semibold)
                    : .systemFont(ofSize: 11)
                label.textColor            = isHeader ? Theme.cornflower : Theme.fg
                label.lineBreakMode        = .byTruncatingTail
                label.maximumNumberOfLines = 1
                label.translatesAutoresizingMaskIntoConstraints = false
                label.setContentHuggingPriority(.defaultLow, for: .horizontal)
                label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                rowView.addSubview(label)
                labels.append(label)
            }

            for (colIdx, label) in labels.enumerated() {
                label.centerYAnchor.constraint(equalTo: rowView.centerYAnchor).isActive = true
                if colIdx == 0 {
                    label.leadingAnchor.constraint(equalTo: rowView.leadingAnchor, constant: 10).isActive = true
                } else {
                    label.leadingAnchor.constraint(equalTo: labels[colIdx - 1].trailingAnchor, constant: 12).isActive = true
                    label.widthAnchor.constraint(equalTo: labels[0].widthAnchor).isActive = true
                }
                if colIdx == colCount - 1 {
                    label.trailingAnchor.constraint(equalTo: rowView.trailingAnchor, constant: -10).isActive = true
                }
            }

            // Row separator
            if !isLast {
                let sep = NSView()
                sep.wantsLayer = true
                sep.layer?.backgroundColor = Theme.borderInactive.withAlphaComponent(0.35).cgColor
                sep.translatesAutoresizingMaskIntoConstraints = false
                rowView.addSubview(sep)
                NSLayoutConstraint.activate([
                    sep.leadingAnchor.constraint(equalTo: rowView.leadingAnchor),
                    sep.trailingAnchor.constraint(equalTo: rowView.trailingAnchor),
                    sep.bottomAnchor.constraint(equalTo: rowView.bottomAnchor),
                    sep.heightAnchor.constraint(equalToConstant: 1),
                ])
            }
        }

        if let last = prevAnchor {
            last.constraint(equalTo: bottomAnchor).isActive = true
        }
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - ToolCallView

private class ToolCallView: NSView {

    init(data: ToolCallData) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.10, alpha: 1).cgColor
        layer?.cornerRadius    = 6

        let iconLabel = NSTextField(labelWithString: icon(for: data.toolName))
        iconLabel.font      = .systemFont(ofSize: 12)
        iconLabel.textColor = Theme.fgMuted
        iconLabel.setContentHuggingPriority(.required, for: .horizontal)

        let nameLabel = NSTextField(labelWithString: data.toolName)
        nameLabel.font      = .systemFont(ofSize: 11, weight: .semibold)
        nameLabel.textColor = Theme.fgMuted
        nameLabel.setContentHuggingPriority(.required, for: .horizontal)

        let dotLabel = NSTextField(labelWithString: "·")
        dotLabel.font      = .systemFont(ofSize: 11)
        dotLabel.textColor = Theme.borderInactive
        dotLabel.setContentHuggingPriority(.required, for: .horizontal)

        let summaryLabel = NSTextField(labelWithString: data.inputSummary)
        // Literal command text (flags like `--stat`, `->` in scripts, etc.) — disable
        // Fira Code's default ligatures so it renders verbatim. See ToolResultView's
        // buildLabelIfNeeded() for the full explanation of this default-on behavior.
        summaryLabel.attributedStringValue = NSAttributedString(string: data.inputSummary, attributes: [
            .font:            Theme.monoFont,
            .foregroundColor: Theme.fg,
            .ligature:        0,
        ])
        summaryLabel.lineBreakMode = .byTruncatingMiddle
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let row = NSStackView(views: [iconLabel, nameLabel, dotLabel, summaryLabel])
        row.orientation = .horizontal
        row.spacing     = 5
        row.alignment   = .centerY
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)

        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -7),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    private func icon(for name: String) -> String {
        switch name {
        case "Read":                         return "📄"
        case "Write":                        return "📝"
        case "Edit", "MultiEdit":            return "✏️"
        case "Bash":                         return "$"
        case "Grep", "Glob":                 return "🔍"
        case "WebFetch", "WebSearch":        return "🌐"
        case "Agent":                        return "🤖"
        case "TodoWrite":                    return "✅"
        case "NotebookRead", "NotebookEdit": return "📓"
        default:                             return "⚙️"
        }
    }
}

// MARK: - ResultChipView

private class ResultChipView: NSView {

    init(data: ResultSummaryData) {
        super.init(frame: .zero)

        let symbol = data.isError ? "✗" : "✓"
        let color  = data.isError ? Theme.redSweater : Theme.sage

        let durationStr = data.durationMs >= 1000
            ? String(format: "%.1fs", Double(data.durationMs) / 1000)
            : "\(data.durationMs)ms"
        let costStr = data.costUSD > 0
            ? String(format: " · $%.4f", data.costUSD)
            : ""
        let labelStr = "\(symbol)  \(durationStr)\(costStr)"

        let label = NSTextField(labelWithString: labelStr)
        label.font      = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - ChatTextView

/// NSTextView subclass that fires `onSubmit` on Return (send) and passes
/// Shift+Return through as a regular newline.
/// Also blocks raw image data reads from the pasteboard to avoid triggering
/// the macOS Photos permission prompt — image files come via drag-and-drop instead.
private class ChatTextView: NSTextView {
    var onSubmit: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        // keyCode 36 = Return; Shift+Return inserts a newline normally
        if event.keyCode == 36, !event.modifierFlags.contains(.shift) {
            onSubmit?()
            return
        }
        super.keyDown(with: event)
    }

    /// Exclude raw image types so NSTextView never reads pixel data from the clipboard.
    /// This prevents the Photos permission prompt that fires even for non-Photos images.
    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        super.readablePasteboardTypes.filter { $0 != .tiff && $0 != .png }
    }
}

// MARK: - ErrorBlockView

private class ErrorBlockView: NSView {

    init(message: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.redSweater.withAlphaComponent(0.08).cgColor
        layer?.cornerRadius    = 6
        layer?.borderWidth     = 1
        layer?.borderColor     = Theme.redSweater.withAlphaComponent(0.4).cgColor

        let label = NSTextField(labelWithString: message)
        // Literal error text — disable Fira Code's default ligatures so it renders
        // verbatim. See ToolResultView's buildLabelIfNeeded() for the full explanation.
        label.attributedStringValue = NSAttributedString(string: message, attributes: [
            .font:            Theme.monoFont,
            .foregroundColor: Theme.redSweater,
            .ligature:        0,
        ])
        label.lineBreakMode       = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - ContextMeterView

/// A 2 px horizontal bar that fills left-to-right proportional to the session's
/// context-window usage. Invisible when `fraction` is nil (no data yet).
class ContextMeterView: NSView {

    /// 0–1 fill fraction, or nil to hide. Set from the main queue.
    var fraction: Double? = nil {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.clear.setFill()
        bounds.fill()

        guard let f = fraction, f > 0 else { return }

        let fillW = bounds.width * CGFloat(min(1.0, f))
        let fillRect = NSRect(x: 0, y: 0, width: fillW, height: bounds.height)

        // Subtle: fgMuted at 60% opacity — visible but not competing with content.
        Theme.fgMuted.withAlphaComponent(0.6).setFill()
        fillRect.fill()
    }
}
