import XCTest
import AppKit
import NostromoKit

// BA2: the scroll-safety gate. Every Mac slice of the Background activity panel is checked with it:
// nothing the panel adds may move the transcript by more than 1 pt, take the composer's focus or
// change its text.
//
// `SafetyRig` is a copy of TF3's private `ScrollRig` (`ToolFoldScrollTests.swift`) with a real
// `ReplInputBar` under the clip view, in a window, holding the first responder with partly typed text
// and a selection. `assertNoMove` runs an event and compares `TranscriptAnchorProbe` snapshots (the
// same ones `nostromo-app transcript-anchor` reports) before and after.
//
// No wall clock, no real pasteboard / UserDefaults / ~/.nostromo.

// MARK: - Content

enum SafetyFixtures {
    /// A complete turn: prose, one group of four calls, then `paragraphs` paragraphs. Tall enough
    /// that a viewport can sit inside it with the group above.
    static func tallTurn(_ n: Int, paragraphs: Int = 10) -> ChatTurn {
        let filler = (0 ..< paragraphs).map {
            TurnBlock.text("turn \(n) paragraph \($0). \(FoldFixtures.prose) \(FoldFixtures.prose) \(FoldFixtures.prose)")
        }
        return FoldFixtures.turn([.text("Turn \(n) opening. \(FoldFixtures.prose)")]
                                 + FoldFixtures.run(4, prefix: "s\(n)_") + filler, user: "turn \(n)")
    }

    static func transcript(_ count: Int = 8) -> [ChatTurn] {
        (0 ..< count).map { tallTurn($0) } + [FoldFixtures.turn([.text("Tail.")], user: "tail")]
    }
}

// MARK: - The rig

final class SafetyRigClip: NSClipView { override var isFlipped: Bool { true } }

final class SafetyRig {
    let contentWidth: CGFloat = 880
    let window: RigWindow
    let scrollView = NSScrollView()
    let clip = SafetyRigClip()
    let doc = RigFlippedDoc()
    let overlay: JumpToLatestOverlay
    let followTail: FollowTailController
    let virtualizer = TurnListVirtualizer()
    /// The pane's holds and answers (the fold choices are in `foldStore`).
    let store = TurnInteractionStore()
    /// The focus's persisted folds and mode (a private file and defaults suite, see `scrollRigFoldStore`).
    let foldStore = scrollRigFoldStore()
    /// The pane's end of `foldStore`: the same `PaneFoldSync` `ReplView` owns.
    var sync: PaneFoldSync!

    var turns: [ChatTurn]
    var materialized: [UUID: ChatTurnView] = [:]
    var pending = Set<UUID>()
    var isMaterializing = false
    var expandedByDefault = false
    var passRequested = false
    var flips: [FollowTailController.Flip] = []
    /// `key=state` for every toggle the operator made, as the pane's `onGroupToggle` saw it.
    var groupToggles: [String] = []
    var autoOpened: [String] = []
    /// `key=state` for every activity-row toggle the operator made, as the pane's `onActivityToggle` saw it.
    var activityToggles: [String] = []
    var coordinator: TranscriptViewportCoordinator!
    /// The pane's roll-in holds: the same `RollInHolds` `ReplView` owns, wired the way `ScrollRig` wires it, so
    /// the gate can run roll-in scenarios.
    var rollInHolds: RollInHolds!
    var reduceMotion = false
    let animator = RigRollInAnimator()
    /// The left mouse button, as the pane would read it from AppKit. A test presses and releases it.
    var mouseDown = false
    /// Work the pane asked to run once the current event is over (a mouse-up, a change of first
    /// responder), held until a test says the event ended.
    private var afterEventQueue: [() -> Void] = []

    /// The composer, laid out under the clip view the way `ReplView` stacks them: its height
    /// constraint drives the clip height.
    let inputBar = ReplInputBar()
    let barHeight: NSLayoutConstraint
    /// What the turn views read background tasks from (BA6c); nil: their rows show none, as before.
    let backgroundTasks: BackgroundRowBinding?

    init(_ testCase: XCTestCase, turns: [ChatTurn], size: NSSize = NSSize(width: 900, height: 600),
         backgroundTasks: BackgroundRowBinding? = nil) {
        self.backgroundTasks = backgroundTasks
        window = makeRigWindow(testCase, size: NSSize(width: size.width, height: size.height + ReplInputBar.minHeight))
        self.turns = turns
        let content = window.contentView!
        overlay = JumpToLatestOverlay(frame: content.bounds)
        overlay.translatesAutoresizingMaskIntoConstraints = false

        inputBar.translatesAutoresizingMaskIntoConstraints = false
        barHeight = inputBar.heightAnchor.constraint(equalToConstant: ReplInputBar.minHeight)
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.contentView = clip
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        doc.frame = NSRect(x: 0, y: 0, width: contentWidth, height: 1)
        scrollView.documentView = doc
        content.addSubview(scrollView)
        content.addSubview(inputBar)
        content.addSubview(overlay, positioned: .above, relativeTo: scrollView)
        NSLayoutConstraint.activate([
            inputBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            inputBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            inputBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            barHeight,
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: inputBar.topAnchor),
            overlay.topAnchor.constraint(equalTo: scrollView.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
        ])
        content.layoutSubtreeIfNeeded()

        followTail = FollowTailController(scrollView: scrollView, overlay: overlay)
        followTail.documentHeight = { [unowned self] in self.virtualizer.documentHeight }
        followTail.contentWidth = { [unowned self] in self.contentWidth }
        followTail.isMaterializing = { [unowned self] in self.isMaterializing }
        followTail.requestPass = { [unowned self] in self.passRequested = true }
        followTail.onFlip = { [unowned self] flip in
            self.flips.append(flip)
            if flip.pinned {
                self.rollInHolds.pinned(jumpedToLatest: flip.cause == .jumpToLatest || flip.cause == .send)
            }
        }
        followTail.onScroll = { [unowned self] in self.rollInHolds.scrolled() }
        virtualizer.foldState = { [unowned self] turn in self.store.state(for: turn.id) }
        sync = PaneFoldSync(tag: "rig", store: foldStore)
        virtualizer.foldResolver = { [unowned self] turn in self.resolver(for: turn) }

        coordinator = TranscriptViewportCoordinator(virtualizer: virtualizer, scrollView: scrollView,
                                                    followTail: followTail, islandFor: { [unowned self] index in
            guard self.turns.indices.contains(index), let view = self.materialized[self.turns[index].id] else { return nil }
            return view
        })
        coordinator.foldChangeApplied = { [unowned self] ids in
            self.pending.formUnion(ids)
            self.virtualizer.splice(turns: self.turns, from: 0)
            self.runPass()
        }
        rollInHolds = RollInHolds(
            scrollView: scrollView, store: store,
            viewFor: { [unowned self] id in self.materialized[id] },
            turnFor: { [unowned self] id in self.turns.first { $0.id == id } },
            applyChange: { [unowned self] ids, mutation in self.coordinator.applyFoldChange(turnIds: ids, mutation: mutation) })
        rollInHolds.isFollowingTail = { [unowned self] in self.followTail.isPinned }
        rollInHolds.reduceMotion = { [unowned self] in self.reduceMotion }
        rollInHolds.animator = animator
        rollInHolds.isLeftMouseDown = { [unowned self] in self.mouseDown }
        rollInHolds.afterEvent = { [unowned self] work in self.afterEventQueue.append(work) }
        rollInHolds.recordCarried = { [unowned self] id, states in
            guard let key = self.turns.first(where: { $0.id == id })?.identityKey else { return }
            for (row, open) in states { self.sync.recordFold(key: row, turnKey: key, open: open) }
        }
        // What `ReplView` hands its `PaneFoldSync`.
        sync.loadedTurnIDs = { [unowned self] in Set(self.turns.map(\.id)) }
        sync.stuckGroupKeys = { [unowned self] in self.stuckGroupKeys() }
        sync.applyChange = { [unowned self] ids, mutation in self.coordinator.applyFoldChange(turnIds: ids, mutation: mutation) }
        sync.reresolve = { [unowned self] in
            for turn in self.turns { self.materialized[turn.id]?.applyFolds(self.resolver(for: turn)) }
        }
    }

    /// How the turn's folds resolve in this pane: the focus's mode and persisted choices
    /// (`expandedByDefault` forces All activity).
    func resolver(for turn: ChatTurn) -> FoldResolver {
        var resolver = sync.resolver(turnKey: turn.identityKey)
        if expandedByDefault { resolver.mode = .allActivity }
        return resolver
    }

    /// The operator's earlier choice for a group of `id`, recorded in the store without a view
    /// being toggled.
    func setGroup(turn id: UUID, key: String, _ open: Bool) {
        sync.recordFold(key: key, turnKey: turns.first { $0.id == id }!.identityKey, open: open)
    }

    /// As `setGroup`, for an activity row.
    func setActivity(turn id: UUID, key: String, _ open: Bool) {
        setGroup(turn: id, key: key, open)
    }

    private func stuckGroupKeys() -> [String] {
        var keys: [String] = []
        func collect(_ item: FoldShape.Item) {
            switch item {
            case .group(let group): if group.isStuck { keys.append(group.key) }
            case .activity(_, let members): members.forEach(collect)
            case .block, .message: break
            }
        }
        for turn in turns where turn.isComplete { virtualizer.foldShape(for: turn)?.items.forEach(collect) }
        return keys
    }

    /// How many pieces of work are waiting for the end of the event.
    var queuedAfterEvent: Int { afterEventQueue.count }

    /// The event is over: run what the pane deferred until now (and what that defers in turn).
    func flushAfterEvent() {
        while !afterEventQueue.isEmpty {
            let work = afterEventQueue
            afterEventQueue = []
            work.forEach { $0() }
        }
    }

    /// Lay the turns out and park at the bottom, like a pane that has been following.
    func start() {
        virtualizer.foldsExpandedByDefault = expandedByDefault
        virtualizer.reset(turns: turns, width: contentWidth)
        doc.setFrameSize(NSSize(width: contentWidth, height: max(virtualizer.documentHeight, clip.bounds.height)))
        followTail.scrollToBottom()
        settle()
        flips = []
    }

    var viewportHeight: CGFloat { clip.bounds.height }

    /// Distance from the bottom of the document to the bottom of the viewport.
    var gapBelowViewport: CGFloat { doc.frame.height - clip.bounds.maxY }

    // MARK: Turn views

    private func makeView(for turn: ChatTurn) -> ChatTurnView {
        let state = store.state(for: turn.id)
        let view = ChatTurnView(turn: turn, contentAvailable: true, interaction: state,
                                folds: resolver(for: turn),
                                heldOrdinals: state.heldOrdinals, backgroundTasks: backgroundTasks)
        let id = turn.id
        rollInHolds.wire(view, turn: id)
        view.onActivityToggle = { [unowned self] key, open in
            self.activityToggles.append("\(key)=\(open)")
            self.setActivity(turn: id, key: key, open)
            self.pending.insert(id)
            if let index = self.turns.firstIndex(where: { $0.id == id }) {
                self.coordinator.noteUserToggle(turnIndex: index, itemKey: key)
            }
        }
        view.onGroupToggle = { [unowned self] key, open in
            self.groupToggles.append("\(key)=\(open)")
            self.setGroup(turn: id, key: key, open)
            self.pending.insert(id)
            if let index = self.turns.firstIndex(where: { $0.id == id }) {
                self.coordinator.noteUserToggle(turnIndex: index, itemKey: key)
            }
        }
        view.onBlockExpansion = { [unowned self] blockIndex, open in
            if let turn = self.turns.first(where: { $0.id == id }) {
                let block = turn.blocks.indices.contains(blockIndex) && blockIndex >= 0 ? turn.blocks[blockIndex] : nil
                self.sync.recordResult(key: FoldKey.result(block: block, index: blockIndex, turnKey: turn.identityKey),
                                       turnKey: turn.identityKey, open: open)
            }
            self.pending.insert(id)
            if let index = self.turns.firstIndex(where: { $0.id == id }) {
                self.coordinator.noteUserToggle(turnIndex: index, itemKey: "b\(blockIndex)")
            }
        }
        view.onIntrinsicHeightChange = { [unowned self] in self.pending.insert(id) }
        // A later member batch is about to change the island's heights: name the reading position first.
        view.onWillChangeHeight = { [unowned self] in self.coordinator.noteProgrammaticChange() }
        view.onAutoOpen = { [unowned self] key in
            self.autoOpened.append(key)
            if let turn = self.turns.first(where: { $0.id == id }) {
                self.sync.recordAuto(key: key, turnKey: turn.identityKey)
            }
        }
        return view
    }

    private func measure(_ view: ChatTurnView, _ turn: ChatTurn, at index: Int) {
        view.setIslandWidth(contentWidth)
        let height = view.islandHeight()
        view.setFrameSize(NSSize(width: contentWidth, height: height))
        let digest = virtualizer.foldDigest(for: turn)
        virtualizer.recordMeasured(height, at: index, isComplete: turn.isComplete, foldDigest: digest)
    }

    // MARK: The pass (ReplView.materialize steps 1 to 5; 1 and 5 are the coordinator's)

    func runPass() {
        guard !isMaterializing else { return }
        isMaterializing = true
        defer { isMaterializing = false }
        passRequested = false

        coordinator.beginPass()
        let viewport = clip.bounds
        if virtualizer.count != turns.count { virtualizer.splice(turns: turns, from: 0) }
        let range = virtualizer.visibleWindow(viewport: coordinator.anticipatedViewport())

        let wanted = Set(turns[range].map { $0.id })
        for (id, view) in materialized where !wanted.contains(id) {
            view.removeFromSuperview()
            materialized.removeValue(forKey: id)
            pending.remove(id)
        }
        for i in range {
            let turn = turns[i]
            if let existing = materialized[turn.id] {
                if pending.contains(turn.id) { measure(existing, turn, at: i) }
            } else {
                let view = makeView(for: turn)
                materialized[turn.id] = view
                measure(view, turn, at: i)
                doc.addSubview(view)
            }
            pending.remove(turn.id)
        }
        for i in range {
            materialized[turns[i].id]?.setFrameOrigin(NSPoint(x: 0, y: virtualizer.offset(of: i)))
        }
        doc.setFrameSize(NSSize(width: contentWidth, height: max(virtualizer.documentHeight, viewport.height)))

        coordinator.endPass()
        followTail.notePassRan()
        window.contentView!.layoutSubtreeIfNeeded()
    }

    /// Passes until the geometry stops changing.
    func settle(maxPasses: Int = 6) {
        for _ in 0 ..< maxPasses {
            let before = (virtualizer.documentHeight, clip.bounds.origin.y)
            runPass()
            let after = (virtualizer.documentHeight, clip.bounds.origin.y)
            if before == after { break }
        }
    }

    // MARK: Operator and stream

    /// The operator moving the viewport. The pane would schedule a pass; callers run it.
    func userScroll(to y: CGFloat) {
        clip.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    /// New blocks arrive for a turn (the last by default), the way `ReplView` handles a delta:
    /// note the change, update the view, refresh the geometry, run the pass.
    func append(_ blocks: [TurnBlock], complete: Bool = false, toTurnAt index: Int? = nil) {
        let i = index ?? turns.count - 1
        coordinator.noteProgrammaticChange()
        turns[i].blocks.append(contentsOf: blocks)
        if complete { turns[i].isComplete = true }
        materialized[turns[i].id]?.update(turn: turns[i])
        virtualizer.refresh(turns[i], at: i)
        pending.insert(turns[i].id)
        runPass()
    }

    func appendTurn(_ turn: ChatTurn) {
        coordinator.noteProgrammaticChange()
        turns.append(turn)
        virtualizer.append(turn)
        runPass()
    }

    func groupView(turn id: UUID, key: String) -> ToolGroupView? {
        materialized[id]?.groupView(forKey: key)
    }

    /// The group row's own click, then the pass the pane would run.
    func toggleRow(turn id: UUID, key: String) {
        guard let view = groupView(turn: id, key: key) else { return XCTFail("no view for group \(key)") }
        view.row.toggle()
        runPass()
    }

    /// The index of the group view among its turn view's subviews.
    func columnIndex(ofGroup key: String, inTurn id: UUID) -> Int? {
        guard let turnView = materialized[id], let group = turnView.groupView(forKey: key) else { return nil }
        return turnView.subviews.firstIndex { $0 === group }
    }

    // MARK: Reading what is on screen

    /// Screen y of `view`'s top edge, relative to the top of the viewport.
    func screenY(of view: NSView) -> CGFloat {
        doc.convert(view.bounds, from: view).minY - clip.bounds.minY
    }
}

// MARK: - The gate

extension SafetyRig {

    /// The composer text a person was typing, and the part of it they had selected.
    static let typedText = "half a thought about the dep"
    static let typedSelection = NSRange(location: 5, length: 6)

    /// A pane that has been following: parked at the true bottom, composer focused.
    static func followingTail(_ testCase: XCTestCase) -> SafetyRig {
        let rig = SafetyRig(testCase, turns: SafetyFixtures.transcript())
        rig.start()
        rig.focusComposer()
        return rig
    }

    /// A pane scrolled up into the middle of the transcript (not following), composer focused.
    static func scrolledUp(_ testCase: XCTestCase) -> SafetyRig {
        let rig = SafetyRig(testCase, turns: SafetyFixtures.transcript())
        rig.start()
        rig.userScroll(to: rig.virtualizer.offset(of: 3) + 40)
        rig.followTail.setPinned(false, cause: .harness)
        rig.settle()
        rig.focusComposer()
        return rig
    }

    var textView: NSTextView { inputBar.textView }

    /// The composer's scroll view (private in `ReplInputBar`).
    var composerScroll: NSScrollView? { textView.enclosingScrollView }

    /// Type something half-finished, select part of it, and make the composer the first responder.
    func focusComposer() {
        textView.string = Self.typedText
        window.makeFirstResponder(textView)
        textView.setSelectedRange(Self.typedSelection)
    }

    /// The durable identity (`ChatTurn.identityKey`) of the turn at the viewport top. The snapshot's own
    /// `turnKey` is the turn's content key, which changes when a block is appended to that turn, so an
    /// event that streams into the turn at the top would false-fail a comparison of it.
    func firstVisibleTurnIdentity() -> String? {
        let index = virtualizer.index(atY: clip.bounds.minY)
        return turns.indices.contains(index) ? turns[index].identityKey : nil
    }

    /// What the probe reports for this pane, taken the way `ReplView.anchorSnapshot` does.
    func snapshot(window index: Int = 0) -> TranscriptAnchorSnapshot {
        let anchor = virtualizer.captureAnchor(viewportTop: clip.bounds.minY) { [unowned self] i, y in
            guard self.turns.indices.contains(i) else { return nil }
            return self.materialized[self.turns[i].id]?.anchorItem(atY: y)
        }
        return TranscriptAnchorProbe.snapshot(
            tag: "gate", window: index, clipBounds: clip.bounds,
            documentHeight: max(doc.frame.height, virtualizer.documentHeight),
            anchor: anchor, following: followTail.isPinned)
    }

    /// Run `event`, let the pane's own pass finish, and assert what the operator sees did not change:
    /// the first visible block and its offset (≤ 1 pt), the bottom when following, the composer's
    /// height and scroll-view frame, first responder, text and selection.
    /// `focusMovesOnPurpose`: the event is the user explicitly moving the keyboard (⇧⌘B into a
    /// popover, or closing it again); the first-responder check is skipped, everything else holds.
    func assertNoMove(_ name: String, following: Bool, focusMovesOnPurpose: Bool = false, event: () -> Void,
                      file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(followTail.isPinned, following, "\(name): setup follows the tail = \(following)", file: file, line: line)
        let before = snapshot()
        let turnBefore = firstVisibleTurnIdentity()
        let barBefore = inputBar.frame.height
        let scrollBefore = composerScroll?.frame
        let responderBefore = window.firstResponder
        let textBefore = textView.string
        let selectionBefore = textView.selectedRange()
        XCTAssertNotNil(before.firstVisible, "\(name): the transcript has a first visible block", file: file, line: line)

        event()
        window.contentView?.layoutSubtreeIfNeeded()
        settle()

        let after = snapshot()
        XCTAssertEqual(firstVisibleTurnIdentity(), turnBefore, "\(name): first visible turn changed", file: file, line: line)
        XCTAssertEqual(after.firstVisible?.itemKey, before.firstVisible?.itemKey, "\(name): first visible item changed", file: file, line: line)
        let drift = abs((after.firstVisible?.offsetPt ?? .infinity) - (before.firstVisible?.offsetPt ?? 0))
        XCTAssertLessThanOrEqual(drift, 1, "\(name): first visible block moved by \(drift) pt", file: file, line: line)
        if following {
            XCTAssertEqual(after.bottomOffsetPt, 0, accuracy: 0.5, "\(name): a following pane stays at the true bottom", file: file, line: line)
            XCTAssertTrue(after.following, "\(name): still following the tail", file: file, line: line)
        }
        XCTAssertEqual(inputBar.frame.height, barBefore, accuracy: 0.5, "\(name): input bar height changed", file: file, line: line)
        XCTAssertEqual(composerScroll?.frame, scrollBefore, "\(name): composer text scroll frame changed", file: file, line: line)
        if !focusMovesOnPurpose {
            XCTAssertTrue(window.firstResponder === responderBefore, "\(name): first responder changed to \(String(describing: window.firstResponder))", file: file, line: line)
        }
        XCTAssertEqual(textView.string, textBefore, "\(name): composer text changed", file: file, line: line)
        XCTAssertEqual(textView.selectedRange(), selectionBefore, "\(name): composer selection changed", file: file, line: line)
    }
}
