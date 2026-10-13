import AppKit
import Combine
import os

/// Transcript layout and measurement — see `docs/diagnostics.md`, "The
/// `transcript` log category".
///
/// `measure()` had no instrumentation of any kind before 2026-09-10, which is
/// why a call that took three and a half minutes and a call that took three
/// milliseconds were indistinguishable from the timeline, and why diagnosing
/// the 2026-09-09 beachball needed a live `sample` of the running process.
private let log = Logger(subsystem: "com.hammer.nostromo", category: "transcript")
private let signposter = OSSignposter(subsystem: "com.hammer.nostromo", category: "transcript")

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
    private var turnViews: [UUID: TurnIsland] = [:]
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

    /// "Jump to latest" pill, shown while the pane is not following the tail.
    private let jumpOverlay = JumpToLatestOverlay()
    /// Whether the transcript auto-scrolls to the newest content, and everything
    /// that decides it (bounds observer, overlay, scroller, catch-up). Cleared
    /// only by the operator scrolling away from the bottom, so a background
    /// stream of blocks doesn't yank the view out from under someone reading
    /// history; set again when they scroll back down or send a message. The rule
    /// lives in `FollowTailPolicy`; the wiring in `FollowTailController`.
    private var followTail: FollowTailController!
    private var isPinnedToBottom: Bool { followTail.isPinned }

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
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        // Follow-tail state: observes the clip view's bounds and live scrolls
        // (scroller drags, scrollToBottom, Home/End post no live-scroll
        // notification, so without the bounds observer the pass would miss them
        // and the operator would drag into a blank region), and drives the
        // overlay and scroller.
        followTail = FollowTailController(scrollView: scrollView, overlay: jumpOverlay)
        followTail.documentHeight  = { [weak self] in self?.virtualizer.documentHeight ?? 0 }
        followTail.contentWidth    = { [weak self] in self?.contentWidth ?? 1 }
        followTail.isMaterializing = { [weak self] in self?.isMaterializing ?? false }
        followTail.requestPass     = { [weak self] in self?.schedulePass() }
        followTail.onFlip          = { [weak self] flip in self?.logFollowTailFlip(flip) }

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
            self.followTail.setPinned(true, cause: .send)
            self.session.send(text, images: images)
        }
        inputBar.onInterrupt = { [weak self] in self?.session.interrupt() }
        addSubview(inputBar)

        // "Jump to latest" — covers exactly the transcript area (so it sits above
        // the quick-action strip / context meter / input bar) and only its pill
        // takes clicks.
        jumpOverlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(jumpOverlay, positioned: .above, relativeTo: scrollView)
        // The whole pane (transcript included) accepts image drops.
        registerForDraggedTypes(ImagePasteboard.draggedTypes)

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

            jumpOverlay.topAnchor.constraint(equalTo: scrollView.topAnchor),
            jumpOverlay.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            jumpOverlay.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            jumpOverlay.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
        ]

        if let strip = quickActionStrip {
            constraints += [
                strip.leadingAnchor.constraint(equalTo: leadingAnchor),
                strip.trailingAnchor.constraint(equalTo: trailingAnchor),
                strip.bottomAnchor.constraint(equalTo: contextMeter.topAnchor),
                strip.heightAnchor.constraint(equalToConstant: QuickActionStripView.height),
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
        guard !isMaterializing else { return }
        guard contentWidth > 1 else {
            // No usable width (collapsed split, not yet laid out): nothing to do
            // now, but a pinned pane must still reach the bottom once it has
            // width again — `FollowTailController.paneMayHaveBecomeUsable` pays this back.
            followTail.notePassSkippedForWidth()
            return
        }
        followTail.notePassRan()
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
                measure(view, turn: turn, at: i, reason: .materialize)   // detached — see `measure`
                documentView.addSubview(view)
            } else if pendingRemeasure.contains(turn.id) {
                measure(turnViews[turn.id]!, turn: turn, at: i, reason: .remeasure)
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
            followTail.scrollToBottom()
        } else if let anchor {
            let top = virtualizer.restoredTop(for: anchor)
            if abs(top - viewport.minY) > 0.5 {
                scrollView.contentView.scroll(NSPoint(x: 0, y: top))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
    }

    /// Build a turn view, hydrating its payload first if it has gone cold.
    private func makeTurnView(for turn: ChatTurn) -> TurnIsland {
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
            self.followTail.setPinned(true, cause: .send)
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
    /// Asks the island for its height rather than reading `fittingSize`. A
    /// `ChatTurnView` already holds a measured height for each of its blocks
    /// (see there), so its answer is a sum and costs nothing in the number of
    /// blocks — where `fittingSize` meant solving the whole turn, which is what
    /// made streaming one long turn a positive-feedback loop with no exit.
    private func measure(_ view: TurnIsland, turn: ChatTurn, at index: Int, reason: MeasureReason) {
        let signpostID = signposter.makeSignpostID()
        let interval   = signposter.beginInterval("measure", id: signpostID)
        let started    = ContinuousClock.now
        defer {
            signposter.endInterval("measure", interval)
            noteMeasureDuration(started.duration(to: .now),
                                view: view, turn: turn, at: index, reason: reason)
        }

        // Measured while **detached**, and that is not incidental.
        //
        // `translatesAutoresizingMaskIntoConstraints = true` makes AppKit install
        // constraints pinning the view's size to its frame the moment it has a
        // superview. Any height read while attached is then just the frame it
        // already has: a newly-created view measures as its zero frame, and a
        // streaming turn re-measured in place keeps reporting the height it had
        // before the block arrived, so the document silently stops growing.
        //
        // Detached, the only constraints in play are the island's own internal
        // layout — which is exactly the question being asked.
        let superview = view.superview
        // Detaching drops a live transcript selection; put it back after.
        let selection = TranscriptSelection.capture(in: view)
        superview.map { _ in view.removeFromSuperview() }

        view.setIslandWidth(contentWidth)
        let height = max(view.islandHeight(), TurnHeightEstimator.minimumTurnHeight)
        view.setFrameSize(NSSize(width: contentWidth, height: height))
        virtualizer.recordMeasured(height, at: index, isComplete: turn.isComplete)

        superview?.addSubview(view)
        selection?.restore()
    }

    /// Which of `materialize()`'s two step-3 call sites asked for a measurement.
    ///
    /// Worth distinguishing because they fail differently: `.materialize` is
    /// paid once per turn entering the viewport, while `.remeasure` is paid
    /// again on *every* streamed block, and it was `.remeasure` the 2026-09-09
    /// stack sample landed in.
    private enum MeasureReason: String {
        case materialize
        case remeasure
    }

    /// One measurement's wall-clock budget.
    ///
    /// The same 250 ms `makeTurnView`'s hydration comment measures itself
    /// against, and the number the load harness's report script grades on. A
    /// measurement is a synchronous main-thread stall, so this is also the
    /// longest the UI can be frozen by one turn entering the viewport.
    static let measureBudgetSeconds: Double = 0.250

    /// How many `measure()` calls have blown `measureBudgetSeconds` in this pane's
    /// lifetime, and the worst one seen. Surfaced through
    /// `TranscriptDiagnostics.Reporting` so a run can be graded without a
    /// debugger — see `docs/diagnostics.md`.
    private(set) var slowMeasureCount = 0
    private(set) var worstMeasureSeconds: Double = 0

    /// Record one measurement, and shout about it if it blew the budget.
    ///
    /// The subview and constraint walk is O(subtree), so it happens *only* on
    /// the already-slow path — a measurement that came in under budget costs
    /// this function two comparisons.
    private func noteMeasureDuration(_ elapsed: Duration, view: NSView, turn: ChatTurn,
                                     at index: Int, reason: MeasureReason) {
        let seconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        worstMeasureSeconds = max(worstMeasureSeconds, seconds)
        guard seconds > Self.measureBudgetSeconds else { return }
        slowMeasureCount += 1
        log.error("""
            slow measure: tag=\(self.session.tag, privacy: .public) turn=\(index, privacy: .public) blocks=\(turn.blocks.count, privacy: .public) subviews=\(Self.subtreeViewCount(view), privacy: .public) constraints=\(Self.subtreeConstraintCount(view), privacy: .public) reason=\(reason.rawValue, privacy: .public) elapsed=\(seconds * 1000, format: .fixed(precision: 1), privacy: .public)ms budget=\(Self.measureBudgetSeconds * 1000, format: .fixed(precision: 0), privacy: .public)ms
            """)
    }

    /// Total Auto Layout constraints held anywhere in `view`'s subtree — the
    /// quantity the solve's cost is superlinear in, so it is the one number
    /// that makes a slow line actionable rather than merely alarming.
    private static func subtreeConstraintCount(_ view: NSView) -> Int {
        view.constraints.count + view.subviews.reduce(0) { $0 + subtreeConstraintCount($1) }
    }

    private static func subtreeViewCount(_ view: NSView) -> Int {
        1 + view.subviews.reduce(0) { $0 + subtreeViewCount($1) }
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

    /// Every flip of the pinned flag is logged with its cause and the pane's
    /// visibility, so a pane that stops following in the field can be attributed
    /// (`log stream --predicate 'category == "transcript"'`).
    private func logFollowTailFlip(_ flip: FollowTailController.Flip) {
        let win = window
        let key = win?.isKeyWindow ?? false
        let visible = win?.isVisible ?? false
        let occluded = win.map { !$0.occlusionState.contains(.visible) } ?? true
        let width = Double(contentWidth)
        let docHeight = Double(virtualizer.documentHeight)
        let visibleMaxY = Double(scrollView.contentView.bounds.maxY)
        let originDelta = flip.originDeltaY.map { String(format: "%.1f", Double($0)) } ?? "n/a"
        let sizeChanged = flip.sizeChanged.map { String($0) } ?? "n/a"
        let tag = session.tag
        log.info("follow-tail \(flip.pinned ? "pinned" : "unpinned", privacy: .public) tag=\(tag, privacy: .public) cause=\(flip.cause.rawValue, privacy: .public) originDelta=\(originDelta, privacy: .public) sizeChanged=\(sizeChanged, privacy: .public) width=\(width) docHeight=\(docHeight) visibleMaxY=\(visibleMaxY) windowKey=\(key) windowVisible=\(visible) occluded=\(occluded)")
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
                    self.followTail.setPinned(true, cause: .harness)
                    self.schedulePass()
                    timer.invalidate()
                    return
                }
            }
            self.followTail.setPinned(false, cause: .harness)
            self.scrollView.contentView.scroll(NSPoint(x: 0, y: y))
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    override func layout() {
        super.layout()
        // A width change invalidates every estimate and every measurement, since
        // both were taken at the old width. Re-estimating five thousand turns is
        // a few million float ops — which is what keeps a resize interactive.
        let width = contentWidth
        followTail.paneMayHaveBecomeUsable()
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

    /// The window whose occlusion we are observing, so a move to another window
    /// (a pane rebuild) swaps the observation rather than stacking a second.
    private weak var observedWindow: NSWindow?

    /// A window coming back from occluded/hidden is the moment a pane that
    /// followed the tail while out of sight must prove it is at the bottom.
    private func observeWindowVisibility() {
        guard window !== observedWindow else { return }
        if let old = observedWindow {
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.didChangeOcclusionStateNotification, object: old)
        }
        observedWindow = window
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowOcclusionChanged),
            name: NSWindow.didChangeOcclusionStateNotification, object: window)
    }

    @objc private func windowOcclusionChanged() {
        guard window?.occlusionState.contains(.visible) == true else { return }
        followTail.paneWasShown()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        followTail.paneWasShown()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            TranscriptFocusPolicy.focusInputIfAppropriate(
                in: window, inputTextView: self.inputBar.textView, transcript: self.scrollView)
        }
        observeWindowVisibility()
        followTail.paneMayHaveBecomeUsable()
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
        // D5: in addition to whatever prompt this action sends, a "Reset
        // Layout" quick action also clears this focus's saved split ratios
        // and forces its `DynamicFocusView` to rebuild from the daemon's
        // tree directly — the prompt alone re-broadcasts the agent's
        // standard layout, but a corrupt saved ratio on disk would still win
        // over that broadcast (see `DynamicFocusView.makeSplitView`'s
        // resize observer). Special-cased on id here rather than adding a
        // client-side-effect field to `QuickAction`: that would need a
        // hand-written `Decodable` (see `Focus.init(from:)`'s note on why a
        // defaulted non-optional field can't just rely on the synthesized
        // one) for what is, so far, exactly one action.
        if action.id == QuickAction.resetLayoutActionID {
            resetOwningLayout()
        }
        if action.clearFirst {
            // Mirror newSessionTapped's local-history clear so the transcript
            // empties immediately, then start a fresh daemon session.
            // No confirmation dialog — quick actions are intentional one-tap affordances.
            session.newSession()
        }
        let prompt = action.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty {
            followTail.setPinned(true, cause: .send)
            session.send(prompt)
        }
    }

    /// Walk up the view hierarchy to find the `DynamicFocusView` that built
    /// this pane as a leaf (see `DynamicFocusView.makeLeafView`) and ask it
    /// to reset this focus's layout. A no-op if this view isn't (yet) under
    /// one — quick actions only fire from an on-screen button, so in
    /// practice that ancestor is always there by the time this runs.
    private func resetOwningLayout() {
        var view: NSView? = superview
        while let current = view {
            if let dynamicFocusView = current as? DynamicFocusView {
                dynamicFocusView.performLayoutReset()
                return
            }
            view = current.superview
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
    var worstMeasureMs: Double          { worstMeasureSeconds * 1000 }
}

// MARK: - ReplClipView

extension ReplView {
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard ImagePasteboard.hasImages(sender.draggingPasteboard) else { return [] }
        inputBar.setDropHighlight(true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        inputBar.setDropHighlight(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        inputBar.setDropHighlight(false)
        return inputBar.attachImages(from: sender.draggingPasteboard)
    }
}

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
