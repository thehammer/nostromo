import AppKit
import Combine
import NostromoKit
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

    /// What a click on a wake marker opens: the task's window on this pane's tag, or the pane's
    /// background list when the store does not know the task (or several events woke the agent).
    private lazy var wakeMarkerRouter: WakeMarkerView.Router = WakeMarkerView.paneRouter(
        openTask: { [weak self] id in
            guard let self else { return true }
            return TaskWindowManager.shared.open(tag: self.session.tag, taskId: id) != nil
        },
        showList: { [weak self] in self?.inputBar.showBackgroundPopover(nil) })

    private var inputBarHeightConstraint: NSLayoutConstraint!

    /// Whether a click that ended on `hit` should hand the keyboard to the composer. Not when the
    /// click landed on a control or link, or left a selection (or another editor) holding the
    /// keyboard: only a plain click on empty pane or plain text takes it.
    static func shouldFocusComposer(hit: NSView?, firstResponder: NSResponder?, composer: NSTextView) -> Bool {
        var view = hit
        while let v = view {
            if v is NSControl { return false }
            view = v.superview
        }
        if firstResponder === composer { return false }
        if let text = firstResponder as? NSTextView {
            if text.isEditable { return false }
            if text.selectedRange().length > 0 { return false }
        } else if firstResponder is NSText {
            return false
        }
        return true
    }

    @objc private func paneClicked(_ g: NSClickGestureRecognizer) {
        guard g.state == .ended else { return }
        let point = g.location(in: self)
        let hit = superview.flatMap { hitTest(convert(point, to: $0)) }
        // Let the click's own handling (selection, links) finish first.
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            guard Self.shouldFocusComposer(
                hit: hit, firstResponder: window.firstResponder, composer: self.inputBar.textView
            ) else { return }
            window.makeFirstResponder(self.inputBar.textView)
        }
    }
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
    /// Run once at the end of the next materialization pass (the load harness's
    /// `group-expand` timing).
    private var afterNextPass: (() -> Void)?
    /// The load harness's Show All (`NOSTROMO_LOAD_FOLD_DEFAULT=expanded`): every focus is in All
    /// activity, whatever the store says. Outside the harness the mode is the focus's own (View ▸
    /// Focus / Show All Activity), else the global default.
    private let foldsExpandedByDefault = TranscriptLoadHarness.foldsExpandedByDefault
    /// This pane's end of the focus's persisted folds and mode (shared with the other windows on
    /// the focus through `TranscriptFoldStore`).
    private let foldSync: PaneFoldSync

    /// "Jump to latest" pill, shown while the pane is not following the tail.
    private let jumpOverlay = JumpToLatestOverlay()
    /// The approval card for this focus, floated over the bottom of the transcript (AP2a).
    private let approvalHost: ApprovalOverlayHost
    /// The "Claude needs you to sign in" card for this focus, floated over the bottom of the transcript (CL2).
    private let signInHost: ClaudeSignInOverlayHost
    /// Whether the transcript auto-scrolls to the newest content, and everything
    /// that decides it (bounds observer, overlay, scroller, catch-up). Cleared
    /// only by the operator scrolling away from the bottom, so a background
    /// stream of blocks doesn't yank the view out from under someone reading
    /// history; set again when they scroll back down or send a message. The rule
    /// lives in `FollowTailPolicy`; the wiring in `FollowTailController`.
    private var followTail: FollowTailController!
    private var isPinnedToBottom: Bool { followTail.isPinned }
    /// Keeps the reading position across a pass, and the toggled row in place (see there).
    private var viewport: TranscriptViewportCoordinator!
    /// Which roll-ins wait for the reader and when they complete (FV3). Per pane, transient.
    private var rollInHolds: RollInHolds!
    /// The elapsed time on running tool-group rows: one tick for the pane, only while needed.
    private let elapsedTicker = ElapsedTicker()
    /// This pane's content-free flight recorder, blank detector and capture trigger
    /// (`docs/pane-blank-capture.md`). Observes only: nothing it does changes rendering, scrolling or measuring.
    private(set) lazy var renderWatch = PaneRenderWatch(subject: self)
    /// The last materialization window and document height the recorder was told about.
    private var lastRecordedWindow: Range<Int>?
    private var lastRecordedDocumentHeight: CGFloat = 0
    /// `shedMaterializedViews` released the views and its pass waits for the compaction to land.
    private var shedInFlight = false
    /// How many times the document view's draw heartbeat has fired (a test proves it is alive).
    private(set) var documentWillDrawCount = 0
    /// Tells VoiceOver about a mode switch made in this pane. A seam: tests capture the text.
    lazy var announceModeChange: (String) -> Void = { [weak self] text in
        guard let self else { return }
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }
    /// "Tool activity finished, N failed calls", for VoiceOver, when this pane is focused.
    private lazy var announcer = ToolActivityAnnouncer(post: ToolActivityAnnouncer.voiceOver(from: self))

    init(tag: String, agentName: String? = nil, displayName: String? = nil,
         workingDirectory: String? = nil, quickActions: [QuickAction] = [],
         foldStore: TranscriptFoldStore = .shared) {
        self.quickActions = quickActions
        foldSync = PaneFoldSync(tag: tag, store: foldStore,
                                harnessMode: TranscriptLoadHarness.foldsExpandedByDefault ? .allActivity : nil)
        // Use the shared registry so multiple windows showing the same tag
        // observe the same session and stay in sync (mirrored).
        let shared = AppStore.shared.session(for: tag, agentName: agentName, displayName: displayName, workingDirectory: workingDirectory)
        session = shared
        // The guard bar names who was blocked (`Blocked: Cody tried to …`).
        approvalHost = ApprovalOverlayHost(tag: tag, store: ApprovalStore.shared, agentName: { shared.agentName },
                                           noticeStates: AppStore.shared.$motherNoticeState.eraseToAnyPublisher())
        let approvals = approvalHost
        // Stacks above an approval card of the same pane without moving it.
        signInHost = ClaudeSignInOverlayHost(tag: tag, store: ClaudeLoginStore.shared, obstructionTop: { [weak approvals] in
            approvals?.subviews.filter { !$0.isHidden }.map(\.frame.maxY).max() ?? 0
        })
        super.init(frame: .zero)
        _ = renderWatch
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
        followTail.onFlip          = { [weak self] flip in
            self?.logFollowTailFlip(flip)
            // Following the tail again: roll-ins the policy no longer holds complete. Jump to
            // latest and a send complete them all.
            if flip.pinned {
                self?.rollInHolds.pinned(jumpedToLatest: flip.cause == .jumpToLatest || flip.cause == .send)
            }
        }
        followTail.onScroll = { [weak self] in self?.rollInHolds.scrolled() }

        viewport = TranscriptViewportCoordinator(
            virtualizer: virtualizer, scrollView: scrollView, followTail: followTail,
            islandFor: { [weak self] index in self?.island(at: index) })
        viewport.foldChangeApplied = { [weak self] turnIds in self?.foldChangeApplied(turnIds) }
        rollInHolds = RollInHolds(
            scrollView: scrollView, store: interactions,
            viewFor: { [weak self] id in self?.turnViews[id] as? ChatTurnView },
            turnFor: { [weak self] id in
                guard let self, let turn = self.session.turns.first(where: { $0.id == id }) else { return nil }
                switch self.session.hydrated(turn) {
                case .full(let hydrated), .unavailable(let hydrated): return hydrated
                }
            },
            applyChange: { [weak self] turnIds, mutation in self?.applyFoldChange(turnIds: turnIds, mutation: mutation) })
        rollInHolds.recordCarried = { [weak self] turn, states in
            guard let self, let key = self.session.turns.first(where: { $0.id == turn })?.identityKey else { return }
            for (row, open) in states { self.foldSync.recordFold(key: row, turnKey: key, open: open) }
        }
        rollInHolds.isFollowingTail = { [weak self] in self?.isPinnedToBottom ?? true }
        elapsedTicker.islands = { [weak self] in
            self?.turnViews.values.compactMap { $0 as? ElapsedTicking } ?? []
        }
        elapsedTicker.isActive = { [weak self] in self?.isVisibleOnScreen ?? false }

        // Fold state is part of a turn's height: the estimate folds through it, and the
        // height cache is keyed by it, so a re-collapsed group never gets its expanded
        // height back.
        virtualizer.foldState = { [weak self] turn in
            self?.interactions.state(for: turn.id) ?? TurnInteractionState()
        }
        virtualizer.foldResolver = { [weak self] turn in
            self?.foldSync.resolver(turnKey: turn.identityKey) ?? FoldResolver(turnKey: turn.identityKey)
        }
        // Another window's toggle, a mode switch or a default change re-resolves this pane's folds
        // with the reading position kept (`applyFoldChange`).
        foldSync.loadedTurnIDs = { [weak self] in Set(self?.session.turns.map(\.id) ?? []) }
        foldSync.turnIDsForTurnKeys = { [weak self] keys in
            Set(self?.session.turns.filter { keys.contains($0.identityKey) }.map(\.id) ?? [])
        }
        foldSync.stuckGroupKeys = { [weak self] in self?.loadedStuckGroupKeys() ?? [] }
        foldSync.applyChange = { [weak self] turnIds, mutation in self?.applyFoldChange(turnIds: turnIds, mutation: mutation) }
        foldSync.reresolve = { [weak self] in self?.resolveMaterializedFolds() }

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
        // The flight recorder's draw heartbeat. `viewWillDraw`, not `draw(_:)`: overriding `draw(_:)`
        // on this view would make AppKit give a document view as tall as the whole transcript a
        // backing store of its own.
        documentView.onWillDraw = { [weak self] in self?.documentViewWillDraw() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(clipBoundsChangedForRecorder),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        // Input bar — fixed at bottom
        inputBar.translatesAutoresizingMaskIntoConstraints = false
        inputBar.onSend = { [weak self] text, images in
            guard let self else { return }
            self.followTail.setPinned(true, cause: .send)
            self.session.send(text, images: images)
        }
        inputBar.onInterrupt = { [weak self] in self?.session.interrupt() }
        // Every window showing this focus binds to the one shared store, so a switch made in
        // any of them (or by an agent, or a script) reaches all their chips.
        inputBar.bindModel(tag: session.tag, agentName: session.agentName, store: ModelStore.shared)
        inputBar.bindBackground(tag: session.tag, store: BackgroundTaskStore.shared, displayName: session.displayName)
        inputBar.backgroundActions = PaneBackgroundActions(pane: self)
        inputBar.bindMode(tag: session.tag, store: foldSync.store,
                          harnessMode: foldsExpandedByDefault ? .allActivity : nil)
        inputBar.onSetMode = { [weak self] mode in self?.setTranscriptViewMode(mode) }
        addSubview(inputBar)

        // "Jump to latest" — covers exactly the transcript area (so it sits above
        // the quick-action strip / context meter / input bar) and only its pill
        // takes clicks.
        jumpOverlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(jumpOverlay, positioned: .above, relativeTo: scrollView)
        // The approval card floats over the same area, above the pill (the card's own Allow
        // and Deny sit where the pill would be). Like the pill's overlay it hit-tests only
        // its card, and it never touches the scroll view's or the input bar's frames.
        approvalHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(approvalHost, positioned: .above, relativeTo: jumpOverlay)
        // The sign-in card sits under the approval card in z-order: a click lands on whichever is on top of it.
        signInHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(signInHost, positioned: .above, relativeTo: jumpOverlay)
        // Esc in the approval card (or collapsing a focused card) hands keyboard focus back to the composer.
        approvalHost.focusComposer = { [weak self] in
            guard let self else { return }
            self.window?.makeFirstResponder(self.inputBar.textView)
        }
        // The whole pane (transcript included) accepts image drops.
        registerForDraggedTypes(ImagePasteboard.draggedTypes)

        // A click anywhere in the pane that did not select text or hit a control puts the keyboard
        // back in the composer. Mouse events still reach the views below (no delay).
        let click = NSClickGestureRecognizer(target: self, action: #selector(paneClicked(_:)))
        click.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(click)

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

            approvalHost.topAnchor.constraint(equalTo: scrollView.topAnchor),
            approvalHost.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            approvalHost.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            approvalHost.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),

            signInHost.topAnchor.constraint(equalTo: scrollView.topAnchor),
            signInHost.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            signInHost.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            signInHost.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
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

        // A "Model changed" note that arrives in the transcript being looked at is read out by
        // VoiceOver. The two windows of one focus each get the note; only the key one speaks.
        session.noteArrived
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in self?.announceNote(text) }
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
        // Name the reading position before anything changes under it (a no-op while following
        // the tail, or when a position is already waiting for the next pass).
        if case .cleared = change {} else { viewport.noteProgrammaticChange() }
        switch change {
        case .cleared:
            viewport.discardPending()
            announcer.reset()
            renderWatch.recorder.record(.transcriptClear, reason: .clear, Double(virtualizer.count),
                                        Double(session.transcriptClears))
            releaseAllTurnViews(reason: .clear)
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
            var splicedAway = 0
            defer {
                if splicedAway > 0 {
                    renderWatch.recorder.record(.viewsEvicted, reason: .splice, Double(splicedAway),
                                                Double(turnViews.count), Double(turns.count))
                }
            }
            for turn in turns[min(from, turns.count)...] {
                if turnViews.removeValue(forKey: turn.id)?.removeFromSuperview() != nil { splicedAway += 1 }
                pendingRemeasure.remove(turn.id)
                session.payloadStore.unpin(turn.id)
                // New content under an old id: whatever was held was about the old content.
                interactions.dropHolds(turn: turn.id)
            }
            // The other half of the bound. A splice is the one event that can
            // remove turns from the list, and the retention cap reports itself as
            // `.spliced(replacedFrom: 0)` — so pruning here also covers dropped
            // history. Deliberately not done on every materialization pass: that
            // would put an O(turns) walk on the hot path, and between splices
            // growth is bounded by the turns a human actually interacted with.
            interactions.prune(keeping: Set(turns.map(\.id)))
            // The same for the persisted choices, which are keyed by durable ids. Only a splice
            // from the start can drop turns; nothing is forgotten on `.cleared` (Clear Context keeps
            // the focus's mode and its folds).
            if from == 0 { foldSync.prune(keepingTurnKeys: Set(turns.map(\.identityKey))) }
            virtualizer.splice(turns: turns, from: from)

        case .appended(let index):
            guard index < turns.count else { return }
            virtualizer.append(turns[index])

        case .updatedBlocks(let index, let addedCount):
            guard index < turns.count else { return }
            let turn = turns[index]
            // A streaming turn is normally materialized, so append only the blocks that are
            // new rather than rebuilding its subtree. The view opens a stuck turn's last group
            // itself (`onAutoOpen`); for one that is not materialized the entry is recorded here.
            if let view = turnViews[turn.id] as? ChatTurnView {
                view.update(turn: turn)
                pendingRemeasure.insert(turn.id)
            } else {
                recordStuckGroup(of: turn)
                // No view to report a group settling, so the pane does, for VoiceOver.
                if addedCount == 1, let group = ToolActivityAnnouncer.groupClosed(byLastBlockOf: turn) {
                    announcer.groupSettled(group, in: self)
                }
            }
            // After the update, so the estimate folds through any auto entry it recorded.
            virtualizer.refresh(turn, at: index)
        }
        // Distinguished from a scroll- or frame-driven request: a content change
        // must never be dropped, whereas a bounds notification the pass caused
        // itself must be.
        contentDirty = true
        schedulePass()
        renderWatch.requestEvaluation()
    }

    /// The materialized island of the turn at geometry index `index`, if any. Resolved through
    /// the virtualizer's own ids: `session.turns` can be a change event ahead of the geometry,
    /// and the same index there may name another turn.
    private func island(at index: Int) -> TurnIsland? {
        virtualizer.turnID(at: index).flatMap { turnViews[$0] }
    }

    /// The turn's index in the geometry (turns move on a splice; views keep the id).
    private func index(ofTurn id: UUID) -> Int? {
        virtualizer.index(ofTurnID: id)
    }

    /// In a window, not hidden, and the window not occluded.
    private var isVisibleOnScreen: Bool {
        guard let window, !isHiddenOrHasHiddenAncestor else { return false }
        return window.occlusionState.contains(.visible)
    }

    /// A fold change made outside this pane's own clicks: the stuck-turn auto-open here, and
    /// TF4's store events (another window, Expand/Collapse All, the default). Keeps the reading
    /// position (`TranscriptViewportCoordinator`): capture → `mutation` → re-measure → pass.
    func applyFoldChange(turnIds: Set<UUID>, mutation: () -> Void) {
        viewport.applyFoldChange(turnIds: turnIds, mutation: mutation)
    }

    /// The turn's block at `index` as it stands (hydrated), nil for a negative (terminal delivery)
    /// or unknown index.
    private func currentBlock(ofTurn id: UUID, at index: Int) -> TurnBlock? {
        guard index >= 0, let turn = session.turns.first(where: { $0.id == id }) else { return nil }
        let blocks: [TurnBlock]
        switch session.hydrated(turn) {
        case .full(let hydrated), .unavailable(let hydrated): blocks = hydrated.blocks
        }
        return blocks.indices.contains(index) ? blocks[index] : nil
    }

    /// Every stuck tool group (derived, `ToolGroup.isStuck`) in the turns the pane holds, folded
    /// into activity rows or not: a mode switch writes these explicitly.
    private func loadedStuckGroupKeys() -> [String] {
        var keys: [String] = []
        func collect(_ item: FoldShape.Item) {
            switch item {
            case .group(let group): if group.isStuck { keys.append(group.key) }
            case .activity(_, let members): members.forEach(collect)
            case .block, .message: break
            }
        }
        for turn in session.turns where turn.isComplete && turn.marker == nil {
            virtualizer.foldShape(for: turn)?.items.forEach(collect)
        }
        return keys
    }

    /// Set the folds of the materialized turn views from the store (the mode or another window's
    /// choice changed them). Called inside `applyFoldChange`, which re-measures afterwards.
    private func resolveMaterializedFolds() {
        for turn in session.turns {
            guard let view = turnViews[turn.id] as? ChatTurnView else { continue }
            view.applyFolds(foldSync.resolver(turnKey: turn.identityKey))
        }
    }

    /// The pane's half of `applyFoldChange`: each changed turn is re-estimated with its new fold
    /// state (or handed back a height measured with it), those on screen are measured again, and
    /// a pass runs. One walk over the geometry, refreshing only the changed turns in place: a
    /// splice here would re-key every turn against `session.turns`, which can be an append ahead.
    private func foldChangeApplied(_ turnIds: Set<UUID>) {
        guard !turnIds.isEmpty else { return }
        renderWatch.noteLegitimateReflow()   // a fold toggle moves the document height a lot, on purpose
        var changed: [UUID: ChatTurn] = [:]
        for turn in session.turns where turnIds.contains(turn.id) { changed[turn.id] = turn }
        for i in 0 ..< virtualizer.count {
            guard let id = virtualizer.turnID(at: i), let turn = changed[id] else { continue }
            virtualizer.refresh(turn, at: i)
            if turnViews[id] != nil { pendingRemeasure.insert(id) }
        }
        contentDirty = true
        schedulePass()
    }

    /// Record the stuck-turn auto-open for a turn that completed while not materialized (the
    /// view does it for one that is). Only a turn that ended in error can be stuck, so the plan
    /// is computed once, at completion, never per streamed block.
    private func recordStuckGroup(of turn: ChatTurn) {
        guard turn.isComplete else { return }
        let outcome = ToolFoldAdapter.outcome(of: turn)
        guard outcome == .completedError || outcome == .errored else { return }
        guard case .group(let group)? = ToolFoldAdapter.plan(turn).last(where: {
            if case .group = $0 { return true } else { return false }
        }), group.isStuck else { return }
        foldSync.recordAuto(key: group.key, turnKey: turn.identityKey)
    }

    /// Tell VoiceOver about a transcript note, when this pane is the one being looked at.
    private func announceNote(_ text: String) {
        guard window?.isKeyWindow == true, !isHiddenOrHasHiddenAncestor else { return }
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
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
            renderWatch.requestEvaluation()
        }

        guard !turns.isEmpty else {
            releaseAllTurnViews(reason: .clear)
            documentView.setFrameSize(NSSize(width: contentWidth,
                                             height: max(1, scrollView.contentView.bounds.height)))
            noteDocumentHeightForRecorder(max(1, scrollView.contentView.bounds.height))
            return
        }

        let viewportBounds = scrollView.contentView.bounds
        // 1. Name where the operator is reading, BEFORE any height changes (unless a change
        //    already did, before it was applied).
        viewport.beginPass()

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
        // Around where step 5 will put the viewport, not where it was before the change.
        let anticipated = viewport.anticipatedViewport()
        let window = virtualizer.visibleWindow(viewport: anticipated)
        assert(window.upperBound <= turns.count,
               "visibleWindow \(window) exceeds \(turns.count) turns — geometry is out of sync")

        // 2. Evict. Removing the subview releases the whole subtree and every
        //    constraint in it — recycling has to actually release, not merely
        //    stop adding.
        let wanted = Set(turns[window].map { $0.id })
        var evicted = 0
        for (id, view) in turnViews where !wanted.contains(id) {
            view.removeFromSuperview()
            turnViews.removeValue(forKey: id)
            pendingRemeasure.remove(id)
            session.payloadStore.unpin(id)
            evicted += 1
        }
        if evicted > 0 {
            renderWatch.recorder.record(.viewsEvicted, reason: .scroll, Double(evicted),
                                        Double(turnViews.count), Double(turns.count))
        }
        if lastRecordedWindow != window {
            lastRecordedWindow = window
            renderWatch.recorder.record(.windowChange, Double(window.lowerBound), Double(window.upperBound - 1),
                                        Double(anticipated.minY), Double(anticipated.maxY))
        }

        // 3. Materialize what is missing and correct its estimated height to the
        //    real measured one.
        var built = 0
        for i in window {
            let turn = turns[i]
            if turnViews[turn.id] == nil {
                let view = makeTurnView(for: turn)
                turnViews[turn.id] = view
                measure(view, turn: turn, at: i, reason: .materialize)   // detached — see `measure`
                documentView.addSubview(view)
                built += 1
            } else if pendingRemeasure.contains(turn.id) {
                measure(turnViews[turn.id]!, turn: turn, at: i, reason: .remeasure)
            }
            pendingRemeasure.remove(turn.id)
        }
        if built > 0 {
            renderWatch.recorder.record(.viewsMaterialized, Double(built), Double(turnViews.count), Double(turns.count))
        }

        // 4. Position, and size the document from the virtualizer's own cache —
        //    never by reading `documentView.frame`, which forces a synchronous
        //    layout pass on a dirty view.
        for i in window {
            turnViews[turns[i].id]?.setFrameOrigin(NSPoint(x: 0, y: virtualizer.offset(of: i)))
        }
        documentView.setFrameSize(NSSize(width: contentWidth,
                                         height: max(virtualizer.documentHeight, viewportBounds.height)))
        noteDocumentHeightForRecorder(max(virtualizer.documentHeight, viewportBounds.height))

        // 5. Put the toggled row or the reading position back, or follow the newest content.
        viewport.endPass()
        // Measuring can land the viewport away from where step 2 expected it, past the turns it
        // materialized: a blank band must not wait for the next unrelated event. (Only when it
        // landed elsewhere, so a viewport the window cannot cover never loops.)
        let landed = scrollView.contentView.bounds
        if abs(landed.minY - anticipated.minY) > 0.5,
           virtualizer.index(atY: landed.minY) < window.lowerBound
            || virtualizer.index(atY: landed.maxY) >= window.upperBound {
            contentDirty = true
        }
        elapsedTicker.reevaluate()
        if let done = afterNextPass {
            afterNextPass = nil
            done()
        }
    }

    // MARK: Flight recorder hooks (observe only)

    /// The document view's height as the pass last set it. Remembered here because reading the view's
    /// frame back is exactly what `materialize` step 4 avoids.
    private func noteDocumentHeightForRecorder(_ height: CGFloat) {
        guard height != lastRecordedDocumentHeight else { return }
        renderWatch.recorder.recordCoalesced(.docHeight, minIntervalMs: 100, Double(lastRecordedDocumentHeight),
                                             Double(height), Double(virtualizer.documentHeight))
        lastRecordedDocumentHeight = height
    }

    /// One scroll of the clip view (coalesced: a scroll gesture is one line saying how many it was).
    @objc private func clipBoundsChangedForRecorder() {
        let bounds = scrollView.contentView.bounds
        renderWatch.recorder.recordCoalesced(.scroll, minIntervalMs: 100, reason: .scroll, Double(bounds.minY),
                                             Double(lastRecordedDocumentHeight), Double(bounds.height))
        renderWatch.requestEvaluation()
    }

    /// Turn views whose frame overlaps the vertical span of `visible` (document coordinates).
    private func turnViewCount(overlapping visible: NSRect) -> Int {
        var rows = 0
        for view in turnViews.values where view.frame.maxY > visible.minY && view.frame.minY < visible.maxY {
            rows += 1
        }
        return rows
    }

    /// The draw heartbeat: the document view is about to be drawn. Records how many turn rows are in
    /// the visible rect, and lets rule (c) ask whether a draw is about to paint none.
    private func documentViewWillDraw() {
        documentWillDrawCount += 1
        guard renderWatch.automaticEvaluation else { return }
        let visible = scrollView.contentView.bounds
        renderWatch.noteDraw(rowsPainted: turnViewCount(overlapping: visible), dirtyRect: visible)
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
        RebuildCounters.note(.turnViewBuilt)

        let state = interactions.state(for: turn.id)
        let turnKey = turn.identityKey
        let view = ChatTurnView(turn: hydrated, contentAvailable: contentAvailable, interaction: state,
                                folds: foldSync.resolver(turnKey: turnKey),
                                heldOrdinals: state.heldOrdinals, approvals: ApprovalStore.shared,
                                backgroundTasks: BackgroundRowBinding(store: BackgroundTaskStore.shared, tag: session.tag),
                                markerRouter: wakeMarkerRouter)
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
        // The toggled row stays where it is on screen (`noteUserToggle`).
        view.onBlockExpansion = { [weak self] blockIndex, isExpanded in
            guard let self else { return }
            let key = FoldKey.result(block: self.currentBlock(ofTurn: turn.id, at: blockIndex), index: blockIndex,
                                     turnKey: turnKey)
            self.foldSync.recordResult(key: key, turnKey: turnKey, open: isExpanded)
            if let index = self.index(ofTurn: turn.id) {
                self.viewport.noteUserToggle(turnIndex: index, itemKey: "b\(blockIndex)")
            }
        }
        // A tool group opened or closed: the choice outlives the view (eviction, width
        // changes), the turn is re-measured through the same path as a result fold, and the
        // clicked row stays where it is on screen.
        view.onGroupToggle = { [weak self] key, isExpanded in
            guard let self else { return }
            self.foldSync.recordFold(key: key, turnKey: turnKey, open: isExpanded)
            if let index = self.index(ofTurn: turn.id) {
                self.viewport.noteUserToggle(turnIndex: index, itemKey: key)
            }
            self.pendingRemeasure.insert(turn.id)
            self.schedulePass()
        }
        // An activity row opened or closed: as for a group.
        view.onActivityToggle = { [weak self] key, isExpanded in
            guard let self else { return }
            self.foldSync.recordFold(key: key, turnKey: turnKey, open: isExpanded)
            if let index = self.index(ofTurn: turn.id) {
                self.viewport.noteUserToggle(turnIndex: index, itemKey: key)
            }
            self.pendingRemeasure.insert(turn.id)
            self.schedulePass()
        }
        // FV3: a newer message rolls the latest one into the activity row unless the reader is
        // looking at it or has text selected in it (`RollInPolicy`); holds are this pane's own.
        rollInHolds.wire(view, turn: turn.id)
        // An open group is about to build its next batch of rows: note the reading position
        // before its height changes.
        view.onWillChangeHeight = { [weak self] in self?.viewport.noteProgrammaticChange() }
        // The turn ended in error and the view opened its last, failed group: record it (TF4
        // keeps it across restarts) through the fold-change entry point, which also keeps the
        // reading position.
        view.onAutoOpen = { [weak self] key in
            guard let self else { return }
            self.applyFoldChange(turnIds: [turn.id]) {
                self.foldSync.recordAuto(key: key, turnKey: turnKey)
            }
        }
        view.onGroupSettled = { [weak self] group in
            guard let self else { return }
            self.announcer.groupSettled(group, in: self)
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
        //
        // Except a `ChatTurnView`: its height is a sum of block heights it measured itself (each
        // block detached on its own), so asking it never reads its frame, and detaching it would
        // only push every view and constraint it holds out of the window's engine and back in.
        // For an expanded 60-call group that round trip was a large part of the expand time.
        let detach = !(view is ChatTurnView)
        let superview = detach ? view.superview : nil
        // Detaching drops a live transcript selection; put it back after.
        let selection = detach ? TranscriptSelection.capture(in: view) : nil
        superview.map { _ in view.removeFromSuperview() }

        view.setIslandWidth(contentWidth)
        let height = max(view.islandHeight(), TurnHeightEstimator.minimumTurnHeight)
        view.setFrameSize(NSSize(width: contentWidth, height: height))
        let digest = virtualizer.foldDigest(for: turn)
        virtualizer.recordMeasured(height, at: index, isComplete: turn.isComplete, foldDigest: digest)

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
        renderWatch.recorder.recordCoalesced(.measureStall, minIntervalMs: PaneRenderWatch.stallRecordIntervalMs,
                                             seconds * 1000, Double(index))
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

    private func releaseAllTurnViews(reason: PaneFlightRecorder.Reason = .shed) {
        releaseTurnViews(reason: reason, keeping: nil)
    }

    /// Release the materialized turn views, except those whose frame intersects `keep` (document
    /// coordinates), which stay as they are: same views, still pinned, never blank.
    private func releaseTurnViews(reason: PaneFlightRecorder.Reason, keeping keep: NSRect?) {
        // Unpinning matters as much as removing. `TurnPayloadStore` refuses to
        // compact a pinned turn, so a release that left the pins behind would
        // make `shedMaterializedViews()` structurally unable to compact the very
        // turns it just released — and the pinned set would grow on every window
        // resize until compaction was defeated entirely. Backwards, for a memory
        // fix.
        var released = 0
        for (id, view) in turnViews {
            if let keep, view.frame.intersects(keep) { continue }
            view.removeFromSuperview()
            turnViews.removeValue(forKey: id)
            pendingRemeasure.remove(id)
            session.payloadStore.unpin(id)
            released += 1
        }
        if keep == nil { pendingRemeasure.removeAll() }
        if released > 0 {
            renderWatch.recorder.record(.viewsEvicted, reason: reason, Double(released),
                                        Double(turnViews.count), Double(session.turns.count))
        }
    }

    /// Release materialized views to let the transcript's retained content compact, and compact it.
    /// Called by `MemoryWatchdog` on the shed path.
    ///
    /// `.offscreenOnly` is what the watchdog's own polling asks for: on a pane the operator can see,
    /// the views in the viewport and one viewport above and below it stay (a shed that blanked the
    /// visible transcript every 30 s was the 2026-10-25 "panes go blank and redraw" report, and it
    /// freed nothing because the memory was elsewhere). Their payloads stay hot, since a view in use
    /// pins its turn. A pane nobody can see has no one to blank, so it releases everything, as does
    /// `.everything` (the OS reporting critical pressure).
    ///
    /// `completion` fires once the session's compaction has landed, so the
    /// watchdog can measure memory that is genuinely free rather than memory it
    /// has merely asked for.
    func shedMaterializedViews(scope: MemoryWatchdog.ShedScope = .everything, completion: @escaping () -> Void = {}) {
        if scope == .offscreenOnly, renderWatch.isPaneVisible {
            let viewport = scrollView.contentView.bounds
            releaseTurnViews(reason: .shed, keeping: viewport.insetBy(dx: 0, dy: -viewport.height))
        } else {
            releaseAllTurnViews(reason: .shed)
        }
        shedInFlight = true
        session.shedRetainedContent { [weak self] in
            self?.shedInFlight = false
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
        // a few million float ops — which is what keeps a resize interactive. (Tool
        // groups don't depend on width: the virtualizer re-estimates them from cached
        // fold shapes rather than re-planning every turn.)
        let width = contentWidth
        renderWatch.noteLayout(width: Double(bounds.width), height: Double(bounds.height),
                               scrollViewHeight: Double(scrollView.frame.height), contentWidth: Double(width))
        renderWatch.requestEvaluation()
        followTail.paneMayHaveBecomeUsable()
        guard width > 1, abs(width - laidOutWidth) > 0.5 else { return }
        laidOutWidth = width
        renderWatch.noteLegitimateReflow()   // the height is re-estimated at the new width, on purpose
        if virtualizer.count == session.turns.count {
            virtualizer.invalidateWidth(width, turns: session.turns)
        } else {
            virtualizer.reset(turns: session.turns, width: width)
        }
        releaseAllTurnViews(reason: .resize)   // every measurement was taken at the old width
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
        elapsedTicker.reevaluate()   // stops while occluded, re-aims when visible again
        guard window?.occlusionState.contains(.visible) == true else { return }
        followTail.paneWasShown()
    }

    override func viewDidHide() {
        super.viewDidHide()
        elapsedTicker.stop()
        renderWatch.pollPaneState()
        renderWatch.updateScheduling()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        elapsedTicker.reevaluate()
        followTail.paneWasShown()
        renderWatch.pollPaneState()
        renderWatch.updateScheduling()
        renderWatch.requestEvaluation()
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        renderWatch.pollPaneState()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        renderWatch.windowChanged(to: window)
        renderWatch.pollPaneState()
        renderWatch.updateScheduling()
        renderWatch.requestEvaluation()
        elapsedTicker.reevaluate()   // stops out of a window
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
    /// Rows the pane shows with folding, and its tool groups (the PRD's rows-per-turn
    /// metric). One walk over the turns, through the virtualizer's cached fold shapes.
    var foldRowCounts: (rows: Int, groups: Int) {
        ToolFoldAdapter.rowCounts(turns: session.turns, resolver: { [foldSync] turn in
            foldSync.resolver(turnKey: turn.identityKey)
        }, shape: { [virtualizer] turn in virtualizer.foldShape(for: turn) })
    }
}

// MARK: - Pane render watch (flight recorder, blank detector)

extension ReplView: PaneRenderSubject {
    var renderWindow: NSWindow? { window }

    /// On screen with a usable size: a pane in a collapsed split has nothing to draw and is not "blank".
    var isRenderVisible: Bool {
        isVisibleOnScreen && scrollView.contentView.bounds.height >= 1 && contentWidth > 1
    }

    /// Materialized turn views whose frame overlaps the clip view's bounds.
    var visibleTurnViewCount: Int { turnViewCount(overlapping: scrollView.contentView.bounds) }

    var viewportHeight: Double { Double(scrollView.contentView.bounds.height) }

    /// A pass is queued or running, a content change asked for one, the views were just shed and
    /// the pass that puts them back waits for the compaction, or `session.turns` is ahead of the
    /// geometry (its change event is still on its way, and the pass it brings will build the views).
    var isRenderPassPending: Bool {
        passPending || isMaterializing || contentDirty || shedInFlight || virtualizer.count != session.turns.count
    }

    /// A deliberate shed released the views and the compaction that precedes the rebuild has not landed.
    var isShedInFlight: Bool { shedInFlight }

    var renderPaneState: (alpha: Double, hidden: Bool, scrollViewHidden: Bool, scrollViewAttached: Bool) {
        (Double(alphaValue), isHidden, scrollView.isHidden, scrollView.superview === self)
    }

    var renderGeometry: [String: Double] {
        [
            "paneWidth": Double(bounds.width), "paneHeight": Double(bounds.height),
            "scrollViewWidth": Double(scrollView.frame.width), "scrollViewHeight": Double(scrollView.frame.height),
            "clipOriginY": Double(scrollView.contentView.bounds.minY),
            "clipWidth": Double(scrollView.contentView.bounds.width),
            "documentFrameHeight": Double(lastRecordedDocumentHeight),
            "virtualizerCount": Double(virtualizer.count),
            "passPending": passPending ? 1 : 0, "materializing": isMaterializing ? 1 : 0,
            "contentDirty": contentDirty ? 1 : 0, "followingTail": isPinnedToBottom ? 1 : 0,
        ]
    }

    /// Test seam: releases every turn view and schedules nothing, which is what the blank looks like.
    func evictAllTurnViewsForTesting() {
        releaseAllTurnViews(reason: .test)
    }

    /// Test seam: whether the document view overrides `draw(_:)` (it must not: see `TranscriptDocumentView`).
    var documentViewOverridesDrawForTesting: Bool {
        let draw = #selector(NSView.draw(_:))
        return class_getInstanceMethod(type(of: documentView), draw) != class_getInstanceMethod(NSView.self, draw)
    }

    /// Test seam: marks the document view dirty so the next real display pass draws it.
    func dirtyDocumentViewForTesting() {
        documentView.setNeedsDisplay(documentView.visibleRect.isEmpty ? documentView.bounds : documentView.visibleRect)
    }

    /// Test seam: what the document view's draw heartbeat does, with the clock passed in.
    @discardableResult
    func simulateDrawPassForTesting(nowMs: Double, wall: Date) -> [PaneBlankDetector.Hit] {
        let visible = scrollView.contentView.bounds
        return renderWatch.noteDraw(rowsPainted: turnViewCount(overlapping: visible), dirtyRect: visible,
                                    nowMs: nowMs, wall: wall)
    }
}

// MARK: - Scroll-safety probe

extension ReplView {
    /// Read-only: the transcript's first visible block and where the viewport sits
    /// (`nostromo-app transcript-anchor`). Lays out nothing, scrolls nothing, changes no state.
    func anchorSnapshot(windowIndex: Int) -> TranscriptAnchorSnapshot {
        let clip = scrollView.contentView
        let anchor = virtualizer.captureAnchor(viewportTop: clip.bounds.minY) { [weak self] index, y in
            self?.island(at: index)?.anchorItem(atY: y)
        }
        return TranscriptAnchorProbe.snapshot(
            tag: session.tag, window: windowIndex, clipBounds: clip.bounds,
            documentHeight: max(scrollView.documentView?.frame.height ?? 0, virtualizer.documentHeight),
            anchor: anchor, following: followTail.isPinned)
    }
}

// MARK: - Load harness

extension ReplView: ToolGroupHarnessDriving {

    /// Open the first group of `callCount` calls and report how long until the pass that
    /// renders it has finished (`completion`), and until every member is built and a pass has
    /// rendered them (`fullyBuilt`: the batches after the first, `ToolGroupView.memberBatchSize`).
    func harnessExpandFirstToolGroup(callCount: Int, completion: @escaping (_ ms: Double?) -> Void,
                                     fullyBuilt: @escaping (_ ms: Double?) -> Void) {
        let turns = session.turns
        var found: (index: Int, turn: ChatTurn, key: String)?
        search: for (i, turn) in turns.enumerated() where ToolFoldAdapter.hasToolBlocks(turn) {
            for case .group(let group) in ToolFoldAdapter.plan(turn) where group.callCount == callCount {
                found = (i, turn, group.key)
                break search
            }
        }
        guard let found else {
            completion(nil)
            fullyBuilt(nil)
            return
        }

        // In the Focus view the group may sit in a collapsed activity row: open that row first
        // (not timed), so the group's own row is there to click.
        let segmentKey = FoldShape(found.turn).items.lazy.compactMap { item -> String? in
            guard case .activity(let key, let members) = item,
                  members.contains(where: { if case .group(let g) = $0 { return g.key == found.key } else { return false } })
            else { return nil }
            return key
        }.first
        if let segmentKey {
            foldSync.recordFold(key: segmentKey, turnKey: found.turn.identityKey, open: true)
            if let view = turnViews[found.turn.id] as? ChatTurnView {
                view.applyFolds(foldSync.resolver(turnKey: found.turn.identityKey))
            }
            virtualizer.refresh(found.turn, at: found.index)
            pendingRemeasure.insert(found.turn.id)
        }

        // First bring the turn on screen (not timed), then click its row the way the
        // operator would and time from the toggle to the end of the pass it schedules.
        followTail.setPinned(false, cause: .harness)
        scrollView.contentView.scroll(NSPoint(x: 0, y: virtualizer.offset(of: found.index)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        afterNextPass = { [weak self] in
            guard let self,
                  let turnView = self.turnViews[found.turn.id] as? ChatTurnView,
                  let group = turnView.groupView(forKey: found.key)
            else {
                completion(nil)
                fullyBuilt(nil)
                return
            }
            let started = ContinuousClock.now
            func elapsedMs() -> Double {
                let elapsed = started.duration(to: .now)
                return Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
            }
            // Every batch re-measures the group and schedules a pass; report after the pass
            // that follows the last one.
            func reportWhenFullyBuilt() {
                guard group.isFullyBuilt else {
                    self.afterNextPass = reportWhenFullyBuilt
                    return
                }
                fullyBuilt(elapsedMs())
            }
            self.afterNextPass = {
                completion(elapsedMs())
                reportWhenFullyBuilt()
            }
            if group.isExpanded { group.row.toggle() }   // an expanded default: close it first
            group.row.toggle()
            // This closure runs at the END of a pass, while `isMaterializing` is still true:
            // `schedulePass()` is suppressed there, and the toggle does not mark the content
            // dirty, so without this no second pass would ever run and the timing would never
            // be reported (the harness' 30 s wait would time out).
            self.contentDirty = true
        }
        contentDirty = true
        schedulePass()
    }
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

    /// The pane's draw heartbeat for its flight recorder. A `viewWillDraw` hook and not a `draw(_:)`
    /// override: an override of `draw(_:)` is what tells AppKit this view paints, and a document view
    /// as tall as the whole transcript would then get a backing store of its own.
    var onWillDraw: (() -> Void)?

    override func viewWillDraw() {
        super.viewWillDraw()
        onWillDraw?()
    }
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

// MARK: - Transcript view mode (FV4)

extension ReplView: TranscriptViewModeTarget, NSMenuItemValidation {

    /// View ▸ Focus (⌥⌘←), the chip, a fold row's context menu.
    @objc func setTranscriptFocusMode(_ sender: Any?) { setTranscriptViewMode(.focus) }

    /// View ▸ Show All Activity (⌥⌘→), the chip, a fold row's context menu.
    @objc func setTranscriptAllActivityMode(_ sender: Any?) { setTranscriptViewMode(.allActivity) }

    /// The pane's focus is in All activity (its effective mode).
    @objc var transcriptShowsAllActivity: Bool { foldSync.mode == .allActivity }

    /// The mode chip in this pane's input bar.
    var transcriptModeChip: TranscriptModeChip { inputBar.modeChip }

    /// This pane's input bar (the composer and its chips).
    var composerBar: ReplInputBar { inputBar }

    /// Switch this pane's focus to `mode`: every fold in the focus takes the mode's state, in every
    /// window on the focus (the store's event reaches them in this same call), and this pane, the
    /// one that performed it, announces it once.
    func setTranscriptViewMode(_ mode: TranscriptViewMode) {
        foldSync.setMode(mode)
        announceModeChange(mode == .focus ? "Focus: activity folded" : "Showing all activity")
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == TranscriptViewMenu.focusAction || menuItem.action == TranscriptViewMenu.allActivityAction {
            return TranscriptViewMenu.validate(menuItem, target: self)
        }
        return true
    }
}

// MARK: - Show in Transcript (BA6c)

/// Which visible item stands for a tool call, without changing any fold.
enum ToolCallLocator {

    /// The newest block of `turn` that is the call `toolUseId`.
    static func blockIndex(of toolUseId: String, in turn: ChatTurn) -> Int? {
        turn.blocks.indices.last { index in
            if case .toolCall(let call) = turn.blocks[index] { return call.toolUseId == toolUseId }
            return false
        }
    }

    /// The anchor key of what shows the call at block `index` as the folds stand: the activity row
    /// when it is folded into a collapsed one, the group's row when its group is collapsed, else the
    /// call's own block (`b<i>`). A subagent's call stands for the Agent/Task call it ran under.
    static func itemKey(forBlock index: Int, in turn: ChatTurn, shape: FoldShape, folds: FoldResolver) -> String? {
        var target = index
        if case .toolCall(let call) = turn.blocks[index], let parent = call.parentToolUseId,
           let parentIndex = blockIndex(of: parent, in: turn) {
            target = parentIndex
        }

        func holds(_ items: [FoldShape.Item]) -> Bool {
            items.contains { item in
                switch item {
                case .block(let i): return i == target
                case .message: return false
                case .group(let group): return group.members.contains(target)
                case .activity(_, let members): return holds(members)
                }
            }
        }

        func resolve(_ items: [FoldShape.Item]) -> String? {
            for item in items {
                switch item {
                case .block(let i):
                    if i == target { return "b\(i)" }
                case .message:
                    continue
                case .group(let group):
                    if group.members.contains(target) {
                        return folds.isExpanded(key: group.key, isStuck: group.isStuck) ? "b\(target)" : group.key
                    }
                case .activity(let key, let members):
                    guard holds(members) else { continue }
                    return folds.isActivityExpanded(key: key) ? resolve(members) : key
                }
            }
            return nil
        }
        return resolve(shape.items)
    }
}

extension ReplView {

    /// Whether the pane's transcript holds a turn with the call `toolUseId` that shows somewhere.
    func canRevealToolCall(toolUseId: String) -> Bool {
        revealTarget(toolUseId: toolUseId) != nil
    }

    /// Scroll the transcript so the item that shows the call `toolUseId` is a third of the way down the
    /// viewport (see `TranscriptViewportCoordinator.reveal`). Expands nothing. False, moving nothing,
    /// if no retained turn holds the call. The only code path of Background Activity that moves the transcript.
    @discardableResult
    func revealToolCall(toolUseId: String) -> Bool {
        guard let target = revealTarget(toolUseId: toolUseId) else { return false }
        var y = documentY(of: target)
        if y == nil {
            // Not materialized: go to the turn, build it, then place the item.
            viewport.reveal(documentY: virtualizer.offset(of: target.index) + scrollView.contentView.bounds.height / 3)
            if contentWidth > 1 { materialize() }
            y = documentY(of: target)
        }
        guard let y else { return true }
        viewport.reveal(documentY: y)
        return true
    }

    /// Show in Transcript, chosen in the Background activity popover: it closes, then the transcript moves.
    func showToolCallFromBackgroundActivity(toolUseId: String) {
        inputBar.closeBackgroundPopover()
        revealToolCall(toolUseId: toolUseId)
    }

    /// This pane's focus tag (the task actions compare it with the popover's).
    var focusTag: String { session.tag }

    private struct RevealTarget {
        let turnID: UUID
        let index: Int
        let itemKey: String
    }

    /// The newest retained turn holding the call, and the item that shows it.
    private func revealTarget(toolUseId: String) -> RevealTarget? {
        for turn in session.turns.reversed() where turn.marker == nil {
            guard let block = ToolCallLocator.blockIndex(of: toolUseId, in: turn),
                  let index = index(ofTurn: turn.id), let shape = virtualizer.foldShape(for: turn)
            else { continue }
            let folds = (turnViews[turn.id] as? ChatTurnView)?.currentFolds ?? foldSync.resolver(turnKey: turn.identityKey)
            if let key = ToolCallLocator.itemKey(forBlock: block, in: turn, shape: shape, folds: folds) {
                return RevealTarget(turnID: turn.id, index: index, itemKey: key)
            }
        }
        return nil
    }

    private func documentY(of target: RevealTarget) -> CGFloat? {
        guard let island = island(at: target.index), let offset = island.offset(ofItemKey: target.itemKey) else { return nil }
        return virtualizer.offset(of: target.index) + offset
    }
}
