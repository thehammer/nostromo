import XCTest
import AppKit
import NostromoKit

// TF3 (transcript tool folds): the transcript keeps still while folds change.
//
// The rig below is a transcript pane that is never on screen: a real `NSScrollView` with a
// flipped clip and document view, a real `TurnListVirtualizer`, real `ChatTurnView`s, a real
// `FollowTailController` and the real `TranscriptViewportCoordinator`. `ReplView` is not
// compiled into the logic-test bundle, so the rig owns a stand-in for the part of
// `ReplView.materialize()` that is not the coordinator's (steps 2 to 4: evict, build and measure,
// position and size the document).
//
// Every assertion about stillness is stated as what an operator sees: the screen y of a
// concrete thing (a group row, a result header, the first item at the top of the viewport),
// read from the views' real frames, before and after. "Moves at most 1 pt."
//
// No wall clock, no sleeps, no real pasteboard / UserDefaults / ~/.nostromo.

private typealias F = FoldFixtures

// MARK: - Content

private func fillerBlocks(_ count: Int, tag: String) -> [TurnBlock] {
    (0 ..< count).map { TurnBlock.text("\(tag) paragraph \($0). \(F.prose) \(F.prose) \(F.prose)") }
}

/// Notes (a boundary: never folded, never a message). Content below a group that leaves the group
/// where it is: under the Focus layout a group with a message after it folds into an activity row,
/// while a group followed only by boundaries is the TF2/TF3 group row at the top level.
private func noteBlocks(_ count: Int, tag: String) -> [TurnBlock] {
    (0 ..< count).map { TurnBlock.note("\(tag) note \($0). \(F.prose) \(F.prose) \(F.prose) \(F.prose)") }
}

/// A complete turn: prose, one group of four calls (`g:h<n>_0`), a note.
private func historyTurn(_ n: Int) -> ChatTurn {
    F.turn([.text("History \(n) opening. \(F.prose)")] + F.run(4, prefix: "h\(n)_")
           + [.note("History \(n) closing. \(F.prose) \(F.prose) \(F.prose)")], user: "history \(n)")
}

/// A complete, tall turn: opening prose, one group of four calls (`g:L<n>_0`), then ten
/// notes, so a viewport can sit inside the turn with the group above it.
private func longTurn(_ n: Int) -> ChatTurn {
    F.turn([.text("Long \(n) opening. \(F.prose)")] + F.run(4, prefix: "L\(n)_") + noteBlocks(10, tag: "long \(n)"),
           user: "long \(n)")
}

/// `count` tall turns and a short complete tail turn.
private func longTranscript(_ count: Int = 8) -> [ChatTurn] {
    var turns: [ChatTurn] = (0 ..< count).map(longTurn)
    turns.append(F.turn([.text("Tail.")], user: "tail"))
    return turns
}

private func errorChip() -> TurnBlock {
    .resultSummary(ResultSummaryData(durationMs: 5, costUSD: 0.01, isError: true))
}

private func disclosureButton(in view: NSView) -> NSButton? {
    rigAllSubviews(of: view).compactMap { $0 as? NSButton }.first
}

// MARK: - The rig

private final class ScrollRigClip: NSClipView { override var isFlipped: Bool { true } }

/// A thing near the top of the viewport, named so it can be found again after its view was rebuilt:
/// the turn, and the index of the item among the turn view's subviews.
private struct ScrollLandmark {
    let turnID: UUID
    let subviewIndex: Int
}

private struct ScrollProbe {
    let landmark: ScrollLandmark
    /// Screen y (relative to the top of the viewport) when it was taken.
    let y: CGFloat
}

private final class ScrollRig {
    let contentWidth: CGFloat = 880
    let window: RigWindow
    let scrollView = NSScrollView()
    let clip = ScrollRigClip()
    let doc = RigFlippedDoc()
    let overlay: JumpToLatestOverlay
    let followTail: FollowTailController
    let virtualizer = TurnListVirtualizer()
    let store = TurnInteractionStore()

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
    /// `key=state` for every activity-row toggle the operator made, as the pane's `onActivityToggle` saw it (FV2).
    var activityToggles: [String] = []
    /// Ordinals the pane was told to hold back (FV2's interim hold), in order.
    var holds: [Int] = []
    /// Overrides the interim hold policy (`!followTail.isPinned`, what `ReplView` wires) for a test
    /// that needs a roll-in to go through while the pane is not following.
    var holdPolicy: (() -> Bool)?
    var coordinator: TranscriptViewportCoordinator!

    init(_ testCase: XCTestCase, turns: [ChatTurn], size: NSSize = NSSize(width: 900, height: 600)) {
        window = makeRigWindow(testCase, size: size)
        self.turns = turns
        let content = window.contentView!
        overlay = JumpToLatestOverlay(frame: content.bounds)
        overlay.autoresizingMask = [.width, .height]

        scrollView.frame = content.bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.contentView = clip
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        doc.frame = NSRect(x: 0, y: 0, width: contentWidth, height: 1)
        scrollView.documentView = doc
        content.addSubview(scrollView)
        content.addSubview(overlay, positioned: .above, relativeTo: scrollView)
        content.layoutSubtreeIfNeeded()

        followTail = FollowTailController(scrollView: scrollView, overlay: overlay)
        followTail.documentHeight = { [unowned self] in self.virtualizer.documentHeight }
        followTail.contentWidth = { [unowned self] in self.contentWidth }
        followTail.isMaterializing = { [unowned self] in self.isMaterializing }
        followTail.requestPass = { [unowned self] in self.passRequested = true }
        followTail.onFlip = { [unowned self] flip in
            self.flips.append(flip)
            // ReplView: becoming pinned (following, or Jump to latest) releases every hold.
            if flip.pinned { self.releaseHolds() }
        }
        virtualizer.foldState = { [unowned self] turn in self.store.state(for: turn.id) }

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
                                folds: FoldResolver(state: state, expandedByDefault: expandedByDefault),
                                heldOrdinals: state.heldOrdinals)
        let id = turn.id
        view.holdsRollIns = { [unowned self] in self.holdPolicy?() ?? !self.followTail.isPinned }
        view.onHold = { [unowned self] ordinal in
            self.holds.append(ordinal)
            self.store.hold(turn: id, ordinal: ordinal)
        }
        view.onActivityToggle = { [unowned self] key, open in
            self.activityToggles.append("\(key)=\(open)")
            self.store.setActivity(turn: id, key: key, open)
            self.pending.insert(id)
            if let index = self.turns.firstIndex(where: { $0.id == id }) {
                self.coordinator.noteUserToggle(turnIndex: index, itemKey: key)
            }
        }
        view.onGroupToggle = { [unowned self] key, open in
            self.groupToggles.append("\(key)=\(open)")
            self.store.setGroup(turn: id, key: key, open)
            self.pending.insert(id)
            if let index = self.turns.firstIndex(where: { $0.id == id }) {
                self.coordinator.noteUserToggle(turnIndex: index, itemKey: key)
            }
        }
        view.onBlockExpansion = { [unowned self] blockIndex, open in
            self.store.setExpanded(turn: id, block: blockIndex, open)
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
            self.store.recordAuto(turn: id, key: key)
        }
        return view
    }

    private func measure(_ view: ChatTurnView, _ turn: ChatTurn, at index: Int) {
        view.setIslandWidth(contentWidth)
        let height = view.islandHeight()
        view.setFrameSize(NSSize(width: contentWidth, height: height))
        let digest = ToolFoldAdapter.foldDigest(turn: turn, state: store.state(for: turn.id),
                                                expandedByDefault: virtualizer.foldsExpandedByDefault)
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

    func activityRow(turn id: UUID, key: String) -> ActivityRowView? {
        materialized[id]?.activityRowView(forKey: key)
    }

    /// The activity row's own click, then the pass the pane would run.
    func toggleActivityRow(turn id: UUID, key: String) {
        guard let view = activityRow(turn: id, key: key) else { return XCTFail("no view for activity row \(key)") }
        view.row.toggle()
        runPass()
    }

    /// What `ReplView` does when the pane becomes pinned: forget every hold and re-present those
    /// turns, off screen, with the reading position anchored.
    func releaseHolds() {
        let ids = store.releaseAllHolds()
        guard !ids.isEmpty else { return }
        coordinator.applyFoldChange(turnIds: ids) {
            for id in ids {
                guard let index = self.turns.firstIndex(where: { $0.id == id }) else { continue }
                self.materialized[id]?.releaseHolds(turn: self.turns[index])
            }
        }
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

    /// The first item (the bubble, a block, a group) that still shows below the top of the viewport.
    func landmarkNearViewportTop() -> ScrollLandmark? {
        for turn in turns {
            guard let view = materialized[turn.id] else { continue }
            for (index, sub) in view.subviews.enumerated() where doc.convert(sub.bounds, from: sub).maxY > clip.bounds.minY + 1 {
                return ScrollLandmark(turnID: turn.id, subviewIndex: index)
            }
        }
        return nil
    }

    func screenY(of landmark: ScrollLandmark) -> CGFloat? {
        guard let view = materialized[landmark.turnID], view.subviews.indices.contains(landmark.subviewIndex) else { return nil }
        return screenY(of: view.subviews[landmark.subviewIndex])
    }

    func probe() -> ScrollProbe? {
        guard let landmark = landmarkNearViewportTop(), let y = screenY(of: landmark) else { return nil }
        return ScrollProbe(landmark: landmark, y: y)
    }

    /// Scroll (as the operator) until the row of group `key` sits `target` points below the top of
    /// the viewport. Returns where it ended up.
    @discardableResult
    func placeRow(turn id: UUID, key: String, atScreenY target: CGFloat) -> CGFloat? {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return nil }
        userScroll(to: virtualizer.offset(of: index))   // bring the turn into the window
        settle()
        for _ in 0 ..< 4 {
            guard let row = groupView(turn: id, key: key)?.row else { return nil }
            userScroll(to: screenY(of: row) + clip.bounds.minY - target)
            settle()
        }
        return groupView(turn: id, key: key).map { screenY(of: $0.row) }
    }

    /// Like `placeRow`, for an activity row.
    @discardableResult
    func placeActivityRow(turn id: UUID, key: String, atScreenY target: CGFloat) -> CGFloat? {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return nil }
        userScroll(to: virtualizer.offset(of: index))
        settle()
        for _ in 0 ..< 4 {
            guard let row = activityRow(turn: id, key: key)?.row else { return nil }
            userScroll(to: screenY(of: row) + clip.bounds.minY - target)
            settle()
        }
        return activityRow(turn: id, key: key).map { screenY(of: $0.row) }
    }
}

/// The regression assertion: what the operator was looking at has not moved.
private func assertStill(_ rig: ScrollRig, _ probe: ScrollProbe, _ context: String,
                         file: StaticString = #filePath, line: UInt = #line) {
    guard let y = rig.screenY(of: probe.landmark) else {
        return XCTFail("the first visible item is no longer on screen: \(context)", file: file, line: line)
    }
    let drift = abs(y - probe.y)
    XCTAssertLessThanOrEqual(drift, 1, "first visible line moved by \(drift) pt (turn-granular anchor?) \(context)",
                             file: file, line: line)
}

// MARK: - Follow-tail and streaming

final class ToolFoldScrollTests: XCTestCase {

    // MARK: following

    func testAFollowingPaneStaysAtTheTrueBottomWhileASixtyCallGroupStreamsIntoTheTail() throws {
        let history = Array(try F.benchmarkTurns().suffix(10))
        let rig = ScrollRig(self, turns: history)
        rig.start()
        rig.appendTurn(F.turn([.text("Running the checks.")], complete: false, user: "check everything"))
        XCTAssertTrue(rig.followTail.isPinned)
        XCTAssertLessThanOrEqual(rig.gapBelowViewport, 0.5)

        for (n, block) in F.run(60, prefix: "live").enumerated() {
            rig.append([block])

            XCTAssertLessThanOrEqual(rig.gapBelowViewport, 0.5, "after block \(n) the viewport ends at the true bottom")
            XCTAssertTrue(rig.followTail.isPinned, "after block \(n)")
        }

        let tail = try XCTUnwrap(rig.turns.last)
        let group = try XCTUnwrap(rig.groupView(turn: tail.id, key: "g:live0"))
        XCTAssertEqual(group.group.callCount, 60)
        XCTAssertFalse(group.isExpanded, "the group stayed collapsed: one 22 pt row")
        XCTAssertTrue(rig.flips.filter { !$0.pinned }.isEmpty, "following never stopped")
    }

    func testAReaderScrolledUpDoesNotMoveWhileASixtyCallGroupStreamsIntoTheTurnTheyAreIn() throws {
        let tail = F.turn(fillerBlocks(24, tag: "tail"), complete: false, user: "tail")
        let rig = ScrollRig(self, turns: (0 ..< 4).map(longTurn) + [tail])
        rig.start()
        rig.userScroll(to: rig.virtualizer.offset(of: rig.turns.count - 1) + 100)
        rig.settle()
        XCTAssertFalse(rig.followTail.isPinned, "precondition: the operator is reading history")
        let probe = try XCTUnwrap(rig.probe())
        XCTAssertEqual(probe.landmark.turnID, tail.id, "precondition: the viewport is inside the streaming turn")

        for (n, block) in F.run(60, prefix: "live").enumerated() {
            rig.append([block])

            assertStill(rig, probe, "after block \(n)")
        }

        XCTAssertFalse(rig.followTail.isPinned, "streaming never re-pins a reader")
    }

    // MARK: the turn-granular anchor regression

    private func stuckTail() -> ChatTurn {
        var blocks = fillerBlocks(3, tag: "intro")
        for i in 0 ..< 6 {
            blocks.append(F.call(id: "s\(i)", summary: "make step\(i)", start: Double(i)))
            blocks.append(F.result(i == 5 ? "exit 2" : "ok", id: "s\(i)", isError: i == 5, time: Double(i) + 0.5))
        }
        blocks += noteBlocks(40, tag: "after")
        return F.turn(blocks, complete: false, user: "tail")
    }

    func testAStuckGroupOpeningAboveTheViewportInTheTurnBeingReadDoesNotMoveTheFirstVisibleLine() throws {
        let tail = stuckTail()
        let rig = ScrollRig(self, turns: (0 ..< 5).map(historyTurn) + [tail])
        rig.start()
        let placed = try XCTUnwrap(rig.placeRow(turn: tail.id, key: "g:s0", atScreenY: -300))
        XCTAssertEqual(placed, -300, accuracy: 2, "precondition: the group row is 300 pt above the top of the viewport")
        XCTAssertFalse(rig.followTail.isPinned)
        let probe = try XCTUnwrap(rig.probe())
        XCTAssertEqual(probe.landmark.turnID, tail.id, "precondition: the first visible item is in the same turn as the group")
        let groupColumn = try XCTUnwrap(rig.columnIndex(ofGroup: "g:s0", inTurn: tail.id))
        XCTAssertGreaterThan(probe.landmark.subviewIndex, groupColumn, "precondition: the group is above the first visible item")

        rig.append([errorChip()], complete: true)

        XCTAssertEqual(rig.groupView(turn: tail.id, key: "g:s0")?.isExpanded, true, "the stuck group opened")
        XCTAssertEqual(rig.autoOpened, ["g:s0"])
        assertStill(rig, probe, "after the stuck group above the viewport opened")
        XCTAssertFalse(rig.followTail.isPinned)
    }

    func testAStuckGroupOpeningInATurnBelowTheViewportDoesNotMoveTheFirstVisibleLine() throws {
        let tail = stuckTail()
        let rig = ScrollRig(self, turns: (0 ..< 5).map(longTurn) + [tail])
        rig.start()
        XCTAssertNotNil(rig.placeRow(turn: rig.turns[2].id, key: "g:L2_0", atScreenY: 150))
        let probe = try XCTUnwrap(rig.probe())

        rig.append([errorChip()], complete: true)

        assertStill(rig, probe, "after a stuck group opened far below")
    }

    // MARK: batch and external changes

    func testAnExpandAllBatchChangeDoesNotMoveTheFirstVisibleLine() throws {
        let rig = ScrollRig(self, turns: longTranscript())
        rig.start()
        let target = rig.turns[4].id
        let placed = try XCTUnwrap(rig.placeRow(turn: target, key: "g:L4_0", atScreenY: -60))
        XCTAssertEqual(placed, -60, accuracy: 2)
        let probe = try XCTUnwrap(rig.probe())
        XCTAssertEqual(probe.landmark.turnID, target, "precondition: first visible item is in the turn whose group is above it")
        let before = rig.virtualizer.documentHeight

        rig.coordinator.applyFoldChange(turnIds: Set(rig.turns.map(\.id))) {
            rig.expandedByDefault = true
            rig.virtualizer.foldsExpandedByDefault = true
            for view in rig.materialized.values { _ = view.applyFolds(FoldResolver(expandedByDefault: true)) }
        }

        XCTAssertEqual(rig.groupView(turn: target, key: "g:L4_0")?.isExpanded, true)
        XCTAssertGreaterThan(rig.virtualizer.documentHeight, before + 200, "every group opened")
        assertStill(rig, probe, "after Expand all")
        XCTAssertFalse(rig.followTail.isPinned)
    }

    func testACollapseAllBatchChangeDoesNotMoveTheFirstVisibleLine() throws {
        let rig = ScrollRig(self, turns: longTranscript())
        rig.expandedByDefault = true
        rig.start()
        let target = rig.turns[4].id
        XCTAssertNotNil(rig.placeRow(turn: target, key: "g:L4_0", atScreenY: -60))
        let probe = try XCTUnwrap(rig.probe())
        XCTAssertEqual(probe.landmark.turnID, target)

        rig.coordinator.applyFoldChange(turnIds: Set(rig.turns.map(\.id))) {
            rig.expandedByDefault = false
            rig.virtualizer.foldsExpandedByDefault = false
            for view in rig.materialized.values { _ = view.applyFolds(FoldResolver(expandedByDefault: false)) }
        }

        XCTAssertEqual(rig.groupView(turn: target, key: "g:L4_0")?.isExpanded, false)
        assertStill(rig, probe, "after Collapse all")
    }

    func testAToggleMadeInAnotherWindowDoesNotMoveTheFirstVisibleLine() throws {
        let rig = ScrollRig(self, turns: longTranscript())
        rig.start()
        let target = rig.turns[4].id
        XCTAssertNotNil(rig.placeRow(turn: target, key: "g:L4_0", atScreenY: -60))
        let probe = try XCTUnwrap(rig.probe())
        XCTAssertEqual(probe.landmark.turnID, target)

        // The same turn, a group above the viewport top.
        rig.coordinator.applyFoldChange(turnIds: [target]) {
            rig.store.setGroup(turn: target, key: "g:L4_0", true)
            let changed = rig.materialized[target]?.applyFolds(FoldResolver(state: rig.store.state(for: target)))
            XCTAssertEqual(changed, true, "the view followed the store")
        }
        XCTAssertEqual(rig.groupView(turn: target, key: "g:L4_0")?.isExpanded, true)
        XCTAssertEqual(rig.groupToggles, [], "an external change is not the operator's toggle")
        assertStill(rig, probe, "after another window opened a group in this turn")

        // A turn far above the viewport that has no view at all: only its estimate changes.
        let far = rig.turns[0].id
        XCTAssertNil(rig.materialized[far], "precondition: no view for a turn this far away")
        rig.coordinator.applyFoldChange(turnIds: [far]) {
            rig.store.setGroup(turn: far, key: "g:L0_0", true)
        }
        assertStill(rig, probe, "after another window opened a group in a turn that has no view")
        XCTAssertFalse(rig.followTail.isPinned)
    }

    func testAnOperatorScrollBetweenANoteAndItsPassIsNotUndone() throws {
        let rig = ScrollRig(self, turns: longTranscript(6))
        rig.start()
        XCTAssertNotNil(rig.placeRow(turn: rig.turns[3].id, key: "g:L3_0", atScreenY: 100))

        rig.coordinator.noteProgrammaticChange()
        let target = rig.clip.bounds.minY + 220
        rig.userScroll(to: target)
        rig.runPass()

        XCTAssertEqual(rig.clip.bounds.minY, target, accuracy: 1, "the operator's own scroll wins over a pending anchor")
    }

    // MARK: toggling a visible row

    func testExpandingAndCollapsingAVisibleGroupKeepsItsRowStillWhenScrolledUp() throws {
        let rig = ScrollRig(self, turns: longTranscript())
        rig.start()
        let target = rig.turns[3].id
        let placed = try XCTUnwrap(rig.placeRow(turn: target, key: "g:L3_0", atScreenY: 150))
        XCTAssertEqual(placed, 150, accuracy: 2)
        XCTAssertFalse(rig.followTail.isPinned)
        let row = try XCTUnwrap(rig.groupView(turn: target, key: "g:L3_0")).row
        let collapsedHeight = rig.virtualizer.height(at: 3)

        rig.toggleRow(turn: target, key: "g:L3_0")

        XCTAssertGreaterThan(rig.virtualizer.height(at: 3), collapsedHeight + 100, "precondition: the group opened")
        XCTAssertEqual(rig.screenY(of: row), placed, accuracy: 1, "expanding moved the row")
        XCTAssertEqual(rig.groupToggles, ["g:L3_0=true"])

        rig.toggleRow(turn: target, key: "g:L3_0")

        XCTAssertEqual(rig.virtualizer.height(at: 3), collapsedHeight, accuracy: 1)
        XCTAssertEqual(rig.screenY(of: row), placed, accuracy: 1, "collapsing moved the row")
        XCTAssertEqual(rig.groupToggles, ["g:L3_0=true", "g:L3_0=false"])
    }

    /// A pinned pane whose tail turn ends with a group row and a closing line: the row is on
    /// screen, near the bottom.
    private func pinnedTailRig() -> (ScrollRig, ChatTurn) {
        let tail = F.turn([.text("Tail opening.")] + F.run(5, prefix: "g"), user: "tail")
        let rig = ScrollRig(self, turns: (0 ..< 4).map(longTurn) + [tail])
        rig.start()
        return (rig, tail)
    }

    func testExpandingAndCollapsingAGroupKeepsItsRowStillInAPinnedPane() throws {
        let (rig, tail) = pinnedTailRig()
        XCTAssertTrue(rig.followTail.isPinned)
        let row = try XCTUnwrap(rig.groupView(turn: tail.id, key: "g:g0")).row
        let before = rig.screenY(of: row)
        XCTAssertGreaterThan(before, 0, "precondition: the row is on screen")
        XCTAssertLessThan(before, rig.viewportHeight)

        rig.toggleRow(turn: tail.id, key: "g:g0")

        XCTAssertEqual(rig.screenY(of: row), before, accuracy: 1, "expanding scrolled the row (it follows the bottom instead of the row?)")

        rig.toggleRow(turn: tail.id, key: "g:g0")

        XCTAssertEqual(rig.screenY(of: row), before, accuracy: 1, "collapsing scrolled the row")
    }

    func testExpandingAGroupNearTheBottomOfAPinnedPaneUnpinsWithTheFoldToggleCauseWhenTheBottomLeavesTheViewport() throws {
        let (rig, tail) = pinnedTailRig()
        XCTAssertTrue(rig.followTail.isPinned)
        rig.flips = []

        rig.toggleRow(turn: tail.id, key: "g:g0")

        let bottomVisible = rig.gapBelowViewport <= 0.5
        XCTAssertFalse(bottomVisible, "precondition: five calls and results pushed the bottom out of view")
        XCTAssertFalse(rig.followTail.isPinned)
        XCTAssertEqual(rig.flips.last?.pinned, false)
        XCTAssertEqual(rig.flips.last?.cause, .foldToggle)
        XCTAssertFalse(rig.overlay.button.isHidden, "the pill is offered")
    }

    func testExpandingAGroupInATranscriptShorterThanTheViewportKeepsFollowing() throws {
        let only = F.turn([.text("Short.")] + F.run(2, prefix: "g"), user: "short")
        let rig = ScrollRig(self, turns: [only])
        rig.start()
        XCTAssertTrue(rig.followTail.isPinned)
        let row = try XCTUnwrap(rig.groupView(turn: only.id, key: "g:g0")).row
        let before = rig.screenY(of: row)

        rig.toggleRow(turn: only.id, key: "g:g0")

        XCTAssertLessThan(rig.virtualizer.documentHeight, rig.viewportHeight, "precondition: it still fits in the viewport")
        XCTAssertTrue(rig.followTail.isPinned, "the bottom is still in view, so the pane keeps following")
        XCTAssertTrue(rig.flips.isEmpty)
        XCTAssertEqual(rig.screenY(of: row), before, accuracy: 1)
    }

    func testCollapsingAGroupAtTheTailKeepsAPinnedPaneAtTheTrueBottom() throws {
        let tail = F.turn([.text("Tail opening.")] + F.run(5, prefix: "g"), user: "tail")
        let rig = ScrollRig(self, turns: (0 ..< 4).map(longTurn) + [tail])
        rig.store.setGroup(turn: tail.id, key: "g:g0", true)
        rig.start()
        XCTAssertTrue(rig.followTail.isPinned)
        XCTAssertEqual(rig.groupView(turn: tail.id, key: "g:g0")?.isExpanded, true, "precondition")
        XCTAssertLessThanOrEqual(rig.gapBelowViewport, 0.5)
        rig.flips = []

        rig.toggleRow(turn: tail.id, key: "g:g0")

        XCTAssertEqual(rig.groupView(turn: tail.id, key: "g:g0")?.isExpanded, false)
        XCTAssertLessThanOrEqual(rig.gapBelowViewport, 0.5, "the viewport ends at the true bottom after the document shrank")
        XCTAssertTrue(rig.followTail.isPinned)
        XCTAssertTrue(rig.flips.filter { !$0.pinned }.isEmpty, "collapsing at the tail must not stop following")
    }

    // MARK: toggling a result inside a group

    private func resultTurn(filler: Int) -> ChatTurn {
        F.turn([.text("Results.")] + F.run(4, prefix: "m", output: { "line a \($0)\nline b\nline c" })
               + noteBlocks(filler, tag: "results"), user: "results")
    }

    func testExpandingAResultInsideAnOpenGroupKeepsItsHeaderStillWhenScrolledUp() throws {
        let results = resultTurn(filler: 4)
        var all: [ChatTurn] = (0 ..< 3).map(longTurn)
        all.append(results)
        all.append(contentsOf: (3 ..< 6).map(longTurn))
        all.append(F.turn([.text("Tail.")], user: "tail"))
        let rig = ScrollRig(self, turns: all)
        rig.store.setGroup(turn: results.id, key: "g:m0", true)
        rig.start()
        let placed = try XCTUnwrap(rig.placeRow(turn: results.id, key: "g:m0", atScreenY: 60))
        XCTAssertEqual(placed, 60, accuracy: 2)
        XCTAssertFalse(rig.followTail.isPinned)
        let group = try XCTUnwrap(rig.groupView(turn: results.id, key: "g:m0"))
        let resultViews = group.memberViews.filter { $0 is ToolResultView }
        XCTAssertEqual(resultViews.count, 4)
        let header = resultViews[1]
        let before = rig.screenY(of: header)
        XCTAssertGreaterThan(before, 0, "precondition: the result header is on screen")
        XCTAssertLessThan(before, rig.viewportHeight - 100)
        let button = try XCTUnwrap(disclosureButton(in: header))

        button.performClick(nil)
        rig.runPass()

        XCTAssertTrue(button.title.hasPrefix("▼"), "precondition: the result opened")
        XCTAssertEqual(rig.screenY(of: header), before, accuracy: 1, "the result's header moved")

        button.performClick(nil)
        rig.runPass()

        XCTAssertEqual(rig.screenY(of: header), before, accuracy: 1, "the result's header moved when it closed")
    }

    func testExpandingAResultInsideAnOpenGroupKeepsItsHeaderStillInAPinnedPane() throws {
        let results = resultTurn(filler: 0)
        let rig = ScrollRig(self, turns: (0 ..< 4).map(longTurn) + [results])
        rig.store.setGroup(turn: results.id, key: "g:m0", true)
        rig.start()
        XCTAssertTrue(rig.followTail.isPinned)
        let group = try XCTUnwrap(rig.groupView(turn: results.id, key: "g:m0"))
        let header = try XCTUnwrap(group.memberViews.filter { $0 is ToolResultView }.dropFirst().first)
        let before = rig.screenY(of: header)
        XCTAssertGreaterThan(before, 0, "precondition: the result header is on screen")
        let button = try XCTUnwrap(disclosureButton(in: header))

        button.performClick(nil)
        rig.runPass()

        XCTAssertTrue(button.title.hasPrefix("▼"), "precondition: the result opened")
        XCTAssertEqual(rig.screenY(of: header), before, accuracy: 1, "the result's header moved (it followed the bottom instead?)")
    }

    // MARK: jump to latest, eviction

    func testJumpToLatestAfterMixedFoldStatesLandsAtTheTrueBottom() throws {
        let history = Array(try F.benchmarkTurns().suffix(6))
        var all: [ChatTurn] = history
        all.append(contentsOf: (0 ..< 4).map(longTurn))
        all.append(F.turn([.text("Tail.")], user: "tail"))
        let rig = ScrollRig(self, turns: all)
        rig.start()
        let operatorTurn = rig.turns[history.count + 2].id
        XCTAssertNotNil(rig.placeRow(turn: operatorTurn, key: "g:L2_0", atScreenY: 120))
        rig.toggleRow(turn: operatorTurn, key: "g:L2_0")                    // one group opened by the operator
        let other = rig.turns[history.count + 1].id
        rig.coordinator.applyFoldChange(turnIds: [other]) {                // another opened from elsewhere
            rig.store.setGroup(turn: other, key: "g:L1_0", true)
            _ = rig.materialized[other]?.applyFolds(FoldResolver(state: rig.store.state(for: other)))
        }
        XCTAssertFalse(rig.followTail.isPinned, "precondition: the operator is reading history")
        rig.flips = []

        rig.followTail.pinToBottomAndScroll(cause: .jumpToLatest)
        rig.settle()

        XCTAssertTrue(rig.followTail.isPinned)
        XCTAssertLessThanOrEqual(rig.gapBelowViewport, 0.5, "the viewport ends at the true bottom")
        XCTAssertEqual(rig.flips.map(\.cause), [.jumpToLatest])
        XCTAssertTrue(rig.overlay.button.isHidden)
    }

    func testEvictingAndRebuildingEveryTurnViewWhileScrolledUpDoesNotMoveTheFirstVisibleLine() throws {
        let rig = ScrollRig(self, turns: longTranscript())
        rig.start()
        XCTAssertNotNil(rig.placeRow(turn: rig.turns[4].id, key: "g:L4_0", atScreenY: -60))
        let probe = try XCTUnwrap(rig.probe())

        for view in rig.materialized.values { view.removeFromSuperview() }
        rig.materialized.removeAll()
        rig.runPass()

        XCTAssertNotNil(rig.materialized[probe.landmark.turnID], "the turn was rebuilt")
        assertStill(rig, probe, "after every view was dropped and rebuilt")
    }

    func testAnAnchorTakenBeforeTheViewsWereDroppedStillHoldsAfterTheyAreRebuilt() throws {
        let rig = ScrollRig(self, turns: longTranscript())
        rig.start()
        XCTAssertNotNil(rig.placeRow(turn: rig.turns[4].id, key: "g:L4_0", atScreenY: -60))
        let probe = try XCTUnwrap(rig.probe())

        rig.coordinator.noteProgrammaticChange()
        for view in rig.materialized.values { view.removeFromSuperview() }
        rig.materialized.removeAll()
        rig.runPass()

        assertStill(rig, probe, "after the anchored turn's view was rebuilt mid-change")
    }
}

// MARK: - The anchor, item level

/// `TurnListVirtualizer.Anchor` names an item inside the turn as well as the turn. Pure geometry:
/// no views.
final class TurnListVirtualizerItemAnchorTests: XCTestCase {

    private func makeVirtualizer(heights: [CGFloat], users: [String]) -> (TurnListVirtualizer, [ChatTurn]) {
        let turns = users.map { F.turn([.text($0)], user: $0) }
        let virtualizer = TurnListVirtualizer()
        virtualizer.reset(turns: turns, width: 900)
        for (i, height) in heights.enumerated() { virtualizer.recordMeasured(height, at: i) }
        return (virtualizer, turns)
    }

    func testAnAnchorTakenWithAnItemResolverNamesTheItemAndTheDistanceIntoIt() throws {
        let (virtualizer, _) = makeVirtualizer(heights: [300, 500, 400], users: ["A", "B", "C"])
        var asked: [(Int, CGFloat)] = []

        let anchor = try XCTUnwrap(virtualizer.captureAnchor(viewportTop: 450) { index, offsetWithinTurn in
            asked.append((index, offsetWithinTurn))
            return (key: "g:k", offset: 30)
        })

        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.0, 1, "the turn at the top of the viewport")
        XCTAssertEqual(asked.first?.1 ?? -1, 150, accuracy: 0.001, "450 minus the turn's top at 300")
        XCTAssertEqual(anchor.index, 1)
        XCTAssertEqual(anchor.offsetWithinTurn, 150, accuracy: 0.001)
        XCTAssertEqual(anchor.itemKey, "g:k")
        XCTAssertEqual(anchor.offsetInItem, 30, accuracy: 0.001)
    }

    func testAnAnchorTakenWithoutAnItemResolverIsTurnLevelOnly() throws {
        let (virtualizer, _) = makeVirtualizer(heights: [300, 500, 400], users: ["A", "B", "C"])

        let anchor = try XCTUnwrap(virtualizer.captureAnchor(viewportTop: 450))

        XCTAssertEqual(anchor.index, 1)
        XCTAssertNil(anchor.itemKey)
        XCTAssertEqual(anchor.offsetInItem, 0)
    }

    func testAnAnchorWhoseTurnHasNoViewFallsBackToTurnLevel() throws {
        let (virtualizer, _) = makeVirtualizer(heights: [300, 500, 400], users: ["A", "B", "C"])

        let anchor = try XCTUnwrap(virtualizer.captureAnchor(viewportTop: 450) { _, _ in nil })

        XCTAssertNil(anchor.itemKey)
        XCTAssertEqual(anchor.offsetWithinTurn, 150, accuracy: 0.001)
    }

    func testTheViewportTopRestoresToTheItemsOffsetPlusTheDistanceIntoIt() throws {
        let (virtualizer, _) = makeVirtualizer(heights: [300, 500, 400], users: ["A", "B", "C"])
        let anchor = try XCTUnwrap(virtualizer.captureAnchor(viewportTop: 450) { _, _ in (key: "g:k", offset: 30) })
        var asked: [(Int, String)] = []

        let top = virtualizer.restoredTop(for: anchor) { index, key in
            asked.append((index, key))
            return 100   // the item now sits 100 pt into its turn
        }

        XCTAssertEqual(top, 300 + 100 + 30, accuracy: 0.001)
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.0, 1)
        XCTAssertEqual(asked.first?.1, "g:k")
    }

    func testAnItemThatNoLongerResolvesFallsBackToTheTurnLevelOffset() throws {
        let (virtualizer, _) = makeVirtualizer(heights: [300, 500, 400], users: ["A", "B", "C"])
        let anchor = try XCTUnwrap(virtualizer.captureAnchor(viewportTop: 450) { _, _ in (key: "g:k", offset: 30) })

        let top = virtualizer.restoredTop(for: anchor) { _, _ in nil }

        XCTAssertEqual(top, 300 + 150, accuracy: 0.001)
        XCTAssertEqual(virtualizer.restoredTop(for: anchor), 450, accuracy: 0.001, "no resolver at all: the turn-level answer")
    }

    func testTheItemIsLookedUpInTheTurnWhereItIsNowNotWhereItWas() throws {
        let (virtualizer, turns) = makeVirtualizer(heights: [300, 500, 400], users: ["A", "B", "C"])
        let anchor = try XCTUnwrap(virtualizer.captureAnchor(viewportTop: 450) { _, _ in (key: "g:k", offset: 30) })
        // A turn arrives above: B is now the third turn.
        let inserted = F.turn([.text("X")], user: "X")
        virtualizer.splice(turns: [inserted] + turns, from: 0)
        for (i, height) in [250, 300, 500, 400].enumerated() { virtualizer.recordMeasured(CGFloat(height), at: i) }
        var askedIndex: Int?

        let top = virtualizer.restoredTop(for: anchor) { index, _ in askedIndex = index; return 100 }

        XCTAssertEqual(askedIndex, 2, "B is found by its content, not by its old index")
        XCTAssertEqual(top, 550 + 100 + 30, accuracy: 0.001)
    }
}

// MARK: - The island's own geometry

/// `TurnIsland`'s item queries: where each top-level item is, in the island's own (flipped)
/// coordinates, computed from cached heights so it is valid before the island's next layout.
final class TurnIslandItemGeometryTests: XCTestCase {

    /// Prose (b0), a group of three calls (blocks 1 to 6, `g:t0`), prose (b7).
    private let blocks: [TurnBlock] = [.text("Opening. \(F.prose)")] + F.run(3) + [.note("Closing. \(F.prose)")]

    private func columns(_ view: ChatTurnView) -> [NSView] {
        view.subviews.filter { !($0 is UserBubbleView) }
    }

    private func makeOpenRig(_ blocks: [TurnBlock], folds: FoldResolver? = nil,
                             textParents: [Int: String] = [:]) -> (TranscriptRig, ChatTurnView) {
        let window = makeRigWindow(self)
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        let doc = RigFlippedDoc(frame: NSRect(x: 0, y: 0, width: 900, height: 1))
        scroll.documentView = doc
        window.contentView!.addSubview(scroll)
        let turn = F.turn(blocks, complete: false, textParents: textParents)
        let view = ChatTurnView(turn: turn, contentAvailable: true, interaction: TurnInteractionState(), folds: folds)
        view.setIslandWidth(900)
        return (TranscriptRig(window: window, scroll: scroll, doc: doc, turn: view, overlay: nil), view)
    }

    // MARK: item offsets and the row

    func testEachItemsOffsetIsWhereItIsDrawn() throws {
        let rig = makeTranscriptRig(self, blocks: blocks)
        let cols = columns(rig.turn)
        XCTAssertEqual(cols.count, 3)

        XCTAssertEqual(try XCTUnwrap(rig.turn.offset(ofItemKey: "b0")), cols[0].frame.minY, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(rig.turn.offset(ofItemKey: "g:t0")), cols[1].frame.minY, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(rig.turn.offset(ofItemKey: "b7")), cols[2].frame.minY, accuracy: 0.5)
    }

    func testAnItemThatIsNotInTheTurnHasNoOffset() {
        let rig = makeTranscriptRig(self, blocks: blocks)

        XCTAssertNil(rig.turn.offset(ofItemKey: "b99"))
        XCTAssertNil(rig.turn.offset(ofItemKey: "g:elsewhere"))
        XCTAssertNil(rig.turn.offset(ofItemKey: ""))
    }

    func testTheRowRectIsTheGroupsTwentyTwoPointRowInTheIslandsCoordinates() throws {
        let rig = makeTranscriptRig(self, blocks: blocks)
        let group = columns(rig.turn)[1]

        let rect = try XCTUnwrap(rig.turn.rowRect(forGroupKey: "g:t0"))

        XCTAssertEqual(rect.minY, group.frame.minY, accuracy: 0.5)
        XCTAssertEqual(rect.minX, group.frame.minX, accuracy: 0.5)
        XCTAssertEqual(rect.width, group.frame.width, accuracy: 0.5)
        XCTAssertEqual(rect.height, ToolGroupRowView.height)
        XCTAssertNil(rig.turn.rowRect(forGroupKey: "g:elsewhere"))
        XCTAssertNil(rig.turn.rowRect(forGroupKey: "b0"), "a block is not a group")
    }

    func testAMemberOfAnExpandedGroupResolvesByItsBlockIndex() throws {
        let rig = makeTranscriptRig(self, blocks: blocks, folds: FoldResolver(expandedByDefault: true))
        let group = try XCTUnwrap(columns(rig.turn)[1] as? ToolGroupView)
        XCTAssertEqual(group.memberViews.count, 6)

        for (member, blockIndex) in zip(group.memberViews, 1 ... 6) {
            let expected = rig.turn.convert(member.bounds, from: member).minY
            XCTAssertEqual(try XCTUnwrap(rig.turn.offset(ofItemKey: "b\(blockIndex)")), expected, accuracy: 0.5, "b\(blockIndex)")
        }
    }

    // MARK: anchorItem

    func testAnchorItemNamesTheItemAtAYAndHowFarIntoItThatYIs() throws {
        let rig = makeTranscriptRig(self, blocks: blocks)
        let cols = columns(rig.turn)

        let inGroup = try XCTUnwrap(rig.turn.anchorItem(atY: cols[1].frame.minY + 5))
        XCTAssertEqual(inGroup.key, "g:t0")
        XCTAssertEqual(inGroup.offset, 5, accuracy: 0.5)

        let inLast = try XCTUnwrap(rig.turn.anchorItem(atY: cols[2].frame.minY + 3))
        XCTAssertEqual(inLast.key, "b7")
        XCTAssertEqual(inLast.offset, 3, accuracy: 0.5)

        let inFirst = try XCTUnwrap(rig.turn.anchorItem(atY: cols[0].frame.minY + 1))
        XCTAssertEqual(inFirst.key, "b0")
    }

    func testAnchorItemInTheGapOrTheBubbleAboveAnItemNamesThatItemWithANegativeOffset() throws {
        let rig = makeTranscriptRig(self, blocks: blocks)
        let cols = columns(rig.turn)
        XCTAssertGreaterThan(cols[0].frame.minY, 5, "precondition: there is a bubble and padding above the first item")

        let aboveFirst = try XCTUnwrap(rig.turn.anchorItem(atY: 0))
        XCTAssertEqual(aboveFirst.key, "b0")
        XCTAssertEqual(aboveFirst.offset, -cols[0].frame.minY, accuracy: 0.5)

        let gapAboveGroup = try XCTUnwrap(rig.turn.anchorItem(atY: cols[1].frame.minY - 1))
        XCTAssertEqual(gapAboveGroup.key, "g:t0")
        XCTAssertEqual(gapAboveGroup.offset, -1, accuracy: 0.5)
    }

    func testAnchorItemInsideAnExpandedGroupNamesTheGroupItself() throws {
        let rig = makeTranscriptRig(self, blocks: blocks, folds: FoldResolver(expandedByDefault: true))
        let group = columns(rig.turn)[1]

        let anchor = try XCTUnwrap(rig.turn.anchorItem(atY: group.frame.minY + 100))

        XCTAssertEqual(anchor.key, "g:t0")
        XCTAssertEqual(anchor.offset, 100, accuracy: 0.5)
    }

    func testAnchorItemBelowTheLastItemIsNil() {
        let rig = makeTranscriptRig(self, blocks: blocks)

        XCTAssertNil(rig.turn.anchorItem(atY: rig.turn.islandHeight() + 50))
        XCTAssertNil(rig.turn.anchorItem(atY: 100_000))
    }

    // MARK: valid before the next layout

    func testTheQueriesAreRightBeforeTheIslandsNextLayoutEvenAfterAnUpdate() throws {
        let (rig, view) = makeOpenRig(Array(blocks.prefix(7)))   // prose and the group, no closing prose yet
        view.update(turn: F.turn(blocks, complete: false))
        // No layout has run since the update: answer from cached heights.
        let before: [(String, CGFloat?)] = ["b0", "g:t0", "b7"].map { ($0, view.offset(ofItemKey: $0)) }
        let beforeRow = view.rowRect(forGroupKey: "g:t0")
        let beforeAnchor = view.anchorItem(atY: (view.offset(ofItemKey: "g:t0") ?? 0) + 4)

        rig.relayout(width: 900)

        let cols = columns(view)
        XCTAssertEqual(cols.count, 3)
        for ((key, offset), column) in zip(before, cols) {
            XCTAssertEqual(try XCTUnwrap(offset, key), column.frame.minY, accuracy: 0.5, "\(key) before layout")
        }
        XCTAssertEqual(try XCTUnwrap(beforeRow).minY, cols[1].frame.minY, accuracy: 0.5)
        XCTAssertEqual(try XCTUnwrap(beforeAnchor).key, "g:t0")
        XCTAssertEqual(try XCTUnwrap(beforeAnchor).offset, 4, accuracy: 0.5)
    }

    func testTheQueriesTrackAGroupThatJustOpened() throws {
        let rig = makeTranscriptRig(self, blocks: blocks)
        let group = try XCTUnwrap(columns(rig.turn)[1] as? ToolGroupView)
        let closingBefore = try XCTUnwrap(rig.turn.offset(ofItemKey: "b7"))

        group.row.toggle()   // the operator opens it; no layout pass has run

        let closingAfter = try XCTUnwrap(rig.turn.offset(ofItemKey: "b7"))
        XCTAssertGreaterThan(closingAfter, closingBefore + 100, "the item below moved down by the opened members")
        XCTAssertNotNil(rig.turn.offset(ofItemKey: "b2"), "its members resolve now")
        rig.relayout(width: 900)
        XCTAssertEqual(closingAfter, columns(rig.turn)[2].frame.minY, accuracy: 0.5)
    }

    // MARK: subagent blocks

    /// 0 prose, 1 Agent call, 2 subagent call, 3 subagent result, 4 subagent prose, 5 the Agent's result.
    private var agentBlocks: [TurnBlock] {
        [.text("intro"),
         F.call("Agent", id: "toolu_agent", summary: "explore the repo"),
         F.call("Bash", id: "sub1", summary: "grep -r foo", parent: "toolu_agent"),
         F.result("foo.txt", id: "sub1", parent: "toolu_agent"),
         .text("the subagent thinks"),
         F.result("report from the agent", id: "toolu_agent")]
    }

    func testASubagentBlockResolvesToTheTopOfItsAgentActivityRowWhenTheGroupIsOpen() throws {
        let (rig, view) = makeOpenRig(agentBlocks, folds: FoldResolver(expandedByDefault: true), textParents: [4: "toolu_agent"])
        rig.relayout(width: 900)
        let group = try XCTUnwrap(columns(view).compactMap { $0 as? ToolGroupView }.first)
        let activity = try XCTUnwrap(group.memberViews.first { $0 is AgentActivityView })
        let expected = view.convert(activity.bounds, from: activity).minY

        for index in [2, 3, 4] {
            XCTAssertEqual(try XCTUnwrap(view.offset(ofItemKey: "b\(index)"), "b\(index)"), expected, accuracy: 0.5,
                           "subagent block \(index) sits in the activity row")
        }
        let call = try XCTUnwrap(group.memberViews.first { $0 is ToolCallView })
        XCTAssertEqual(try XCTUnwrap(view.offset(ofItemKey: "b1")), view.convert(call.bounds, from: call).minY, accuracy: 0.5,
                       "the Agent call itself still resolves to its own row")
        XCTAssertGreaterThan(expected, try XCTUnwrap(view.offset(ofItemKey: "b1")))
    }

    func testASubagentBlockOfACollapsedGroupDoesNotResolve() {
        let (rig, view) = makeOpenRig(agentBlocks, textParents: [4: "toolu_agent"])
        rig.relayout(width: 900)

        XCTAssertNil(view.offset(ofItemKey: "b3"))
    }

    // MARK: markers

    func testAMarkerTurnHasNoItems() {
        let marker = MarkerTurnView(marker: .gap)

        XCTAssertNil(marker.anchorItem(atY: 10))
        XCTAssertNil(marker.offset(ofItemKey: "b0"))
        XCTAssertNil(marker.rowRect(forGroupKey: "g:x"))
    }
}

// MARK: - Opening a big group while scrolled up (TF3 addendum)

/// The member batches of a big group, collected so a test runs one, then the pass the pane
/// would run after it.
private final class ScrollBatchCollector {
    private var queue: [() -> Void] = []
    func schedule(_ work: @escaping () -> Void) { queue.append(work) }
    var pendingCount: Int { queue.count }

    @discardableResult
    func runNext() -> Bool {
        guard !queue.isEmpty else { return false }
        queue.removeFirst()()
        return true
    }
}

final class ToolGroupExpandScrollTests: XCTestCase {

    /// Opening prose, one 60-call group (`g:B0`, 120 members), ten notes.
    private func bigTurn() -> ChatTurn {
        F.turn([.text("Big opening. \(F.prose)")] + F.run(60, prefix: "B") + noteBlocks(10, tag: "big"), user: "big")
    }

    private func bigRig() -> (ScrollRig, ChatTurn) {
        let big = bigTurn()
        var all: [ChatTurn] = (0 ..< 3).map(longTurn)
        all.append(big)
        all.append(contentsOf: (3 ..< 6).map(longTurn))
        all.append(F.turn([.text("Tail.")], user: "tail"))
        return (ScrollRig(self, turns: all), big)
    }

    func testOpeningASixtyCallGroupScrolledUpKeepsItsRowAndTheFirstVisibleLineStillThroughEveryBatch() throws {
        let (rig, big) = bigRig()
        rig.start()
        let placed = try XCTUnwrap(rig.placeRow(turn: big.id, key: "g:B0", atScreenY: 150))
        XCTAssertEqual(placed, 150, accuracy: 2)
        XCTAssertFalse(rig.followTail.isPinned, "precondition: the operator is reading history")
        let group = try XCTUnwrap(rig.groupView(turn: big.id, key: "g:B0"))
        let collector = ScrollBatchCollector()
        group.scheduleBatch = { collector.schedule($0) }
        let probe = try XCTUnwrap(rig.probe())

        rig.toggleRow(turn: big.id, key: "g:B0")   // the click and its pass

        XCTAssertTrue(group.isExpanded)
        XCTAssertFalse(group.isFullyBuilt, "precondition: members are still being built")
        XCTAssertEqual(rig.groupToggles, ["g:B0=true"])
        XCTAssertEqual(rig.screenY(of: group.row), placed, accuracy: 1, "the click moved the row")
        assertStill(rig, probe, "after the click")

        var batches = 0
        while collector.runNext() {
            batches += 1
            XCTAssertLessThan(batches, 20, "the batches never end")
            rig.runPass()
            XCTAssertEqual(rig.screenY(of: group.row), placed, accuracy: 1, "batch \(batches) moved the row")
            assertStill(rig, probe, "after batch \(batches)")
        }

        XCTAssertGreaterThan(batches, 0)
        XCTAssertTrue(group.isFullyBuilt)
        XCTAssertEqual(group.memberViews.count, group.group.memberIndices.count)
        XCTAssertEqual(collector.pendingCount, 0)
        XCTAssertFalse(rig.followTail.isPinned)
    }

    func testTheTurnsMeasuredHeightEndsWhereAnOpenFromTheStartTurnWouldBe() throws {
        let (rig, big) = bigRig()
        rig.start()
        XCTAssertNotNil(rig.placeRow(turn: big.id, key: "g:B0", atScreenY: 150))
        let group = try XCTUnwrap(rig.groupView(turn: big.id, key: "g:B0"))
        let collector = ScrollBatchCollector()
        group.scheduleBatch = { collector.schedule($0) }
        let index = try XCTUnwrap(rig.turns.firstIndex { $0.id == big.id })

        rig.toggleRow(turn: big.id, key: "g:B0")
        while collector.runNext() { rig.runPass() }
        rig.settle()

        var open = TurnInteractionState()
        open.groupStates["g:B0"] = true
        let fresh = ChatTurnView(turn: big, contentAvailable: true, interaction: open, folds: FoldResolver(state: open))
        fresh.setIslandWidth(rig.contentWidth)
        XCTAssertEqual(rig.virtualizer.height(at: index), fresh.islandHeight(), accuracy: 1,
                       "the virtualizer still holds an estimate for the turn")
    }
}

// MARK: - Where the pass will put the viewport

/// `TranscriptViewportCoordinator.anticipatedViewport()`: the pass materializes the turns around
/// where `endPass` is about to put the viewport, not where it was.
final class TranscriptViewportAnticipationTests: XCTestCase {

    func testAPinnedPaneAnticipatesTheViewportAtTheBottom() {
        let rig = ScrollRig(self, turns: longTranscript(4))
        rig.start()
        XCTAssertTrue(rig.followTail.isPinned)

        let viewport = rig.coordinator.anticipatedViewport()

        XCTAssertEqual(viewport.height, rig.viewportHeight, accuracy: 0.01)
        XCTAssertEqual(viewport.origin.y, max(0, rig.virtualizer.documentHeight - rig.viewportHeight), accuracy: 0.5)
    }

    func testAPinnedPaneFollowsADocumentThatGrewBeforeThePassRan() {
        let rig = ScrollRig(self, turns: longTranscript(4))
        rig.start()
        let before = rig.coordinator.anticipatedViewport().origin.y

        let extra = longTurn(9)
        rig.turns.append(extra)
        rig.virtualizer.append(extra)

        let viewport = rig.coordinator.anticipatedViewport()
        XCTAssertGreaterThan(viewport.origin.y, before + 100, "the new turn is below")
        XCTAssertEqual(viewport.origin.y, max(0, rig.virtualizer.documentHeight - rig.viewportHeight), accuracy: 0.5)
    }

    func testAShortDocumentAnticipatesTheTopWhenPinned() {
        let rig = ScrollRig(self, turns: [F.turn([.text("Short.")], user: "short")])
        rig.start()

        XCTAssertEqual(rig.coordinator.anticipatedViewport().origin.y, 0, accuracy: 0.01)
    }

    func testWithNothingPendingAndNotPinnedTheViewportIsWhereItIs() throws {
        let rig = ScrollRig(self, turns: longTranscript())
        rig.start()
        XCTAssertNotNil(rig.placeRow(turn: rig.turns[4].id, key: "g:L4_0", atScreenY: 100))
        XCTAssertFalse(rig.followTail.isPinned)

        let viewport = rig.coordinator.anticipatedViewport()

        XCTAssertEqual(viewport.origin.y, rig.clip.bounds.origin.y, accuracy: 0.01)
        XCTAssertEqual(viewport.size.height, rig.clip.bounds.size.height, accuracy: 0.01)
    }

    func testAReaderWithAPendingAnchorAnticipatesWhereTheAnchorWillRestoreTo() throws {
        let rig = ScrollRig(self, turns: longTranscript())
        rig.start()
        XCTAssertNotNil(rig.placeRow(turn: rig.turns[4].id, key: "g:L4_0", atScreenY: -60))
        XCTAssertFalse(rig.followTail.isPinned)
        let top = rig.clip.bounds.minY
        let turnTopBefore = rig.virtualizer.offset(of: 4)

        rig.coordinator.noteProgrammaticChange()
        // A geometry change above the reader: a group in an earlier turn opened elsewhere.
        rig.store.setGroup(turn: rig.turns[2].id, key: "g:L2_0", true)
        rig.virtualizer.splice(turns: rig.turns, from: 0)
        let growth = rig.virtualizer.offset(of: 4) - turnTopBefore
        XCTAssertGreaterThan(growth, 50, "precondition: the turns above grew")

        let viewport = rig.coordinator.anticipatedViewport()

        XCTAssertEqual(viewport.origin.y, top + growth, accuracy: 1, "the anchored turn moved down by what grew above it")
        XCTAssertEqual(rig.clip.bounds.minY, top, accuracy: 0.01, "anticipating does not scroll anything")
    }

    func testARowAnchorAnticipatesTheViewportThatKeepsTheRowStill() throws {
        let rig = ScrollRig(self, turns: longTranscript())
        rig.start()
        XCTAssertNotNil(rig.placeRow(turn: rig.turns[4].id, key: "g:L4_0", atScreenY: 150))
        let top = rig.clip.bounds.minY
        let turnTopBefore = rig.virtualizer.offset(of: 4)

        rig.coordinator.noteUserToggle(turnIndex: 4, itemKey: "g:L4_0")
        rig.store.setGroup(turn: rig.turns[2].id, key: "g:L2_0", true)
        rig.virtualizer.splice(turns: rig.turns, from: 0)
        let growth = rig.virtualizer.offset(of: 4) - turnTopBefore
        XCTAssertGreaterThan(growth, 50, "precondition: the turns above grew")

        let viewport = rig.coordinator.anticipatedViewport()

        XCTAssertEqual(viewport.origin.y, top + growth, accuracy: 1, "the toggled row stays at the same screen y")
    }

    func testTheAnticipatedViewportNeverLeavesTheDocument() throws {
        let rig = ScrollRig(self, turns: longTranscript())
        rig.start()
        XCTAssertNotNil(rig.placeRow(turn: rig.turns[1].id, key: "g:L1_0", atScreenY: 20))
        rig.coordinator.noteProgrammaticChange()

        let viewport = rig.coordinator.anticipatedViewport()

        XCTAssertGreaterThanOrEqual(viewport.origin.y, 0)
        XCTAssertLessThanOrEqual(viewport.origin.y, max(0, rig.virtualizer.documentHeight - rig.viewportHeight) + 0.5)
    }
}

// MARK: - A later batch must not move what is read below the group

/// A turn that ends in error with a long failing group (`g:e0`, 36 calls, 72 members) whose
/// results carry long multi-line errors, then paragraphs after it. The stuck-turn rule opens
/// the group; 24 members are built at once and the rest in batches, each of which changes the
/// island's height (estimates become measurements).
final class ToolGroupBatchAnchorScrollTests: XCTestCase {

    private func failingTail() -> ChatTurn {
        var blocks = fillerBlocks(3, tag: "intro")
        for i in 0 ..< 36 {
            blocks.append(F.call(id: "e\(i)", summary: "make step\(i)", start: Double(i)))
            let error = (0 ..< 6).map { "error line \($0) of step \(i): the linker could not resolve a symbol" }.joined(separator: "\n")
            blocks.append(F.result(error, id: "e\(i)", isError: true, time: Double(i) + 0.5))
        }
        // Notes, not paragraphs: a message after the group would fold it into an activity row.
        blocks += noteBlocks(30, tag: "closing")
        return F.turn(blocks, complete: false, user: "tail")
    }

    private func makeRig() -> (ScrollRig, ChatTurn, ScrollBatchCollector) {
        let tail = failingTail()
        let rig = ScrollRig(self, turns: (0 ..< 5).map(historyTurn) + [tail])
        rig.start()
        return (rig, tail, ScrollBatchCollector())
    }

    func testReadingTheClosingProseBelowAStuckGroupDoesNotMoveThroughItsBatches() throws {
        let (rig, tail, collector) = makeRig()
        let placed = try XCTUnwrap(rig.placeRow(turn: tail.id, key: "g:e0", atScreenY: -300))
        XCTAssertEqual(placed, -300, accuracy: 2, "precondition: the group row is above the top of the viewport")
        XCTAssertFalse(rig.followTail.isPinned)
        let group = try XCTUnwrap(rig.groupView(turn: tail.id, key: "g:e0"))
        group.scheduleBatch = { collector.schedule($0) }
        let probe = try XCTUnwrap(rig.probe())
        XCTAssertEqual(probe.landmark.turnID, tail.id)
        let groupColumn = try XCTUnwrap(rig.columnIndex(ofGroup: "g:e0", inTurn: tail.id))
        XCTAssertGreaterThan(probe.landmark.subviewIndex, groupColumn, "precondition: the reader is below the group")

        rig.append([errorChip()], complete: true)

        XCTAssertTrue(group.isExpanded, "the stuck group opened")
        XCTAssertFalse(group.isFullyBuilt, "precondition: members are still queued")
        assertStill(rig, probe, "after the stuck group opened")

        var batches = 0
        while collector.runNext() {
            batches += 1
            XCTAssertLessThan(batches, 20, "the batches never end")
            rig.runPass()
            assertStill(rig, probe, "after batch \(batches)")
        }

        XCTAssertGreaterThan(batches, 0)
        XCTAssertTrue(group.isFullyBuilt)
        XCTAssertFalse(rig.followTail.isPinned)
    }

    func testReadingInsideTheBuiltPartOfAStuckGroupDoesNotMoveThroughItsBatches() throws {
        let (rig, tail, collector) = makeRig()
        let group = try XCTUnwrap(rig.groupView(turn: tail.id, key: "g:e0"))
        group.scheduleBatch = { collector.schedule($0) }
        rig.append([errorChip()], complete: true)
        XCTAssertTrue(group.isExpanded, "the stuck group opened")
        XCTAssertFalse(group.isFullyBuilt, "precondition: members are still queued")

        // The operator scrolls so the group's row is above the top and a built member straddles it.
        rig.userScroll(to: rig.virtualizer.offset(of: rig.turns.count - 1))
        rig.settle()
        let placed = try XCTUnwrap(rig.placeRow(turn: tail.id, key: "g:e0", atScreenY: -100))
        XCTAssertEqual(placed, -100, accuracy: 2)
        XCTAssertFalse(rig.followTail.isPinned)
        let top = rig.clip.bounds.minY
        let member = try XCTUnwrap(group.memberViews.first { rig.doc.convert($0.bounds, from: $0).maxY > top + 1 },
                                   "precondition: a built member is at the top of the viewport")
        let before = rig.screenY(of: member)
        let probe = try XCTUnwrap(rig.probe())

        var batches = 0
        while collector.runNext() {
            batches += 1
            XCTAssertLessThan(batches, 20)
            rig.runPass()
            XCTAssertEqual(rig.screenY(of: member), before, accuracy: 1, "batch \(batches) moved the member being read")
            assertStill(rig, probe, "after batch \(batches)")
        }

        XCTAssertGreaterThan(batches, 0)
        XCTAssertTrue(group.isFullyBuilt)
    }
}

// MARK: - Turn ids in the virtualizer's geometry

final class TurnListVirtualizerTurnIDTests: XCTestCase {

    private func turns(_ names: String...) -> [ChatTurn] { names.map { F.turn([.text($0)], user: $0) } }

    private func ids(_ v: TurnListVirtualizer) -> [UUID?] { (0 ..< v.count).map { v.turnID(at: $0) } }

    private func make(_ list: [ChatTurn]) -> TurnListVirtualizer {
        let v = TurnListVirtualizer()
        v.reset(turns: list, width: 900)
        return v
    }

    func testIdsFollowReset() {
        let list = turns("A", "B", "C")
        let v = make(list)

        XCTAssertEqual(ids(v), list.map { Optional($0.id) })
        for (i, turn) in list.enumerated() { XCTAssertEqual(v.index(ofTurnID: turn.id), i) }
    }

    func testAnUnknownIdOrIndexHasNoAnswer() {
        let v = make(turns("A", "B"))

        XCTAssertNil(v.index(ofTurnID: UUID()))
        XCTAssertNil(v.turnID(at: 2))
        XCTAssertNil(v.turnID(at: -1))
        XCTAssertNil(TurnListVirtualizer().turnID(at: 0))
    }

    func testIdsFollowAnAppend() {
        let list = turns("A", "B")
        let v = make(list)
        let more = F.turn([.text("C")], user: "C")

        v.append(more)

        XCTAssertEqual(v.turnID(at: 2), more.id)
        XCTAssertEqual(v.index(ofTurnID: more.id), 2)
        XCTAssertEqual(v.index(ofTurnID: list[0].id), 0)
    }

    func testIdsFollowASpliceThatReplacesTheTail() {
        let list = turns("A", "B", "C")
        let v = make(list)
        let replacement = turns("X", "Y")

        v.splice(turns: [list[0]] + replacement, from: 1)

        XCTAssertEqual(ids(v), ([list[0]] + replacement).map { Optional($0.id) })
        XCTAssertNil(v.index(ofTurnID: list[1].id), "a replaced turn is gone")
        XCTAssertEqual(v.index(ofTurnID: replacement[1].id), 2)
    }

    func testIdsFollowASpliceToAShorterList() {
        let list = turns("A", "B", "C", "D")
        let v = make(list)

        v.splice(turns: Array(list.prefix(2)), from: 0)

        XCTAssertEqual(v.count, 2)
        XCTAssertEqual(ids(v), list.prefix(2).map { Optional($0.id) })
        XCTAssertNil(v.turnID(at: 3))
        XCTAssertNil(v.index(ofTurnID: list[3].id))
    }

    func testIdsFollowTheRemovalOfTheFrontTurns() {
        let list = turns("A", "B", "C")
        let v = make(list)

        v.splice(turns: Array(list.dropFirst()), from: 0)

        XCTAssertEqual(ids(v), list.dropFirst().map { Optional($0.id) })
        XCTAssertNil(v.index(ofTurnID: list[0].id))
        XCTAssertEqual(v.index(ofTurnID: list[1].id), 0)
        XCTAssertEqual(v.index(ofTurnID: list[2].id), 1)
    }

    func testIdsFollowAnInsertionAtTheFront() {
        let list = turns("A", "B")
        let v = make(list)
        let front = F.turn([.text("X")], user: "X")

        v.splice(turns: [front] + list, from: 0)

        XCTAssertEqual(v.index(ofTurnID: front.id), 0)
        XCTAssertEqual(v.index(ofTurnID: list[0].id), 1)
        XCTAssertEqual(v.index(ofTurnID: list[1].id), 2)
    }

    func testARefreshedTurnKeepsItsIdWhileItsContentChanges() {
        let list = turns("A", "B", "C")
        let v = make(list)
        var grown = list[1]
        grown.blocks.append(.text("more"))

        v.refresh(grown, at: 1)

        XCTAssertEqual(v.turnID(at: 1), list[1].id)
        XCTAssertEqual(v.index(ofTurnID: list[1].id), 1)
        XCTAssertEqual(ids(v), list.map { Optional($0.id) })
    }

    func testARefreshWithADifferentTurnTakesOverTheSlot() {
        let list = turns("A", "B", "C")
        let v = make(list)
        let other = F.turn([.text("Z")], user: "Z")

        v.refresh(other, at: 1)

        XCTAssertEqual(v.turnID(at: 1), other.id)
        XCTAssertNil(v.index(ofTurnID: list[1].id))
    }

    func testIdsFollowAWidthInvalidation() {
        let list = turns("A", "B")
        let v = make(list)
        let swapped = turns("X", "Y")

        v.invalidateWidth(700, turns: swapped)

        XCTAssertEqual(ids(v), swapped.map { Optional($0.id) })
        XCTAssertNil(v.index(ofTurnID: list[0].id))
    }

    func testIdsFollowAWidthInvalidationThatChangesTheTurnCount() {
        let list = turns("A", "B")
        let v = make(list)
        let more = turns("A", "B", "C", "D")

        v.invalidateWidth(700, turns: more)

        XCTAssertEqual(v.count, 4)
        XCTAssertEqual(ids(v), more.map { Optional($0.id) })
    }
}

// MARK: - A cleared transcript

extension TranscriptViewportAnticipationTests {

    func testADiscardedPendingPositionIsNotRestoredAndTheViewportIsAnticipatedWhereItIs() throws {
        let rig = ScrollRig(self, turns: longTranscript())
        rig.start()
        XCTAssertNotNil(rig.placeRow(turn: rig.turns[4].id, key: "g:L4_0", atScreenY: -60))
        XCTAssertFalse(rig.followTail.isPinned)
        let top = rig.clip.bounds.minY
        let turnTopBefore = rig.virtualizer.offset(of: 4)
        rig.coordinator.noteProgrammaticChange()
        rig.store.setGroup(turn: rig.turns[2].id, key: "g:L2_0", true)
        rig.virtualizer.splice(turns: rig.turns, from: 0)
        XCTAssertGreaterThan(rig.virtualizer.offset(of: 4) - turnTopBefore, 50, "precondition: restoring would move the viewport")

        rig.coordinator.discardPending()

        XCTAssertEqual(rig.coordinator.anticipatedViewport().origin.y, top, accuracy: 0.01)
        rig.coordinator.endPass()
        XCTAssertEqual(rig.clip.bounds.minY, top, accuracy: 0.5, "the old anchor was restored after the transcript was cleared")
    }

    func testDiscardingWithNothingPendingChangesNothing() throws {
        let rig = ScrollRig(self, turns: longTranscript())
        rig.start()
        XCTAssertNotNil(rig.placeRow(turn: rig.turns[3].id, key: "g:L3_0", atScreenY: 100))
        let top = rig.clip.bounds.minY

        rig.coordinator.discardPending()
        rig.coordinator.endPass()

        XCTAssertEqual(rig.clip.bounds.minY, top, accuracy: 0.01)
    }
}

// MARK: - Subagent blocks and the row anchor

final class ToolFoldSubagentScrollTests: XCTestCase {

    func testExpandingAnAgentActivityAndASubagentResultInAPinnedPaneKeepsTheActivityRowStill() throws {
        let blocks: [TurnBlock] = [
            .text("Delegating. \(F.prose)"),
            F.call("Agent", id: "toolu_agent", summary: "explore the repo"),
            F.call("Bash", id: "sub1", summary: "grep -r foo", parent: "toolu_agent"),
            F.result("hit one\nhit two\nhit three", id: "sub1", parent: "toolu_agent"),
            .text("the subagent thinks"),
            F.result("report from the agent", id: "toolu_agent"),
        ]
        let tail = F.turn(blocks, complete: false, user: "tail", textParents: [4: "toolu_agent"])
        let rig = ScrollRig(self, turns: (0 ..< 4).map(longTurn) + [tail])
        rig.store.setGroup(turn: tail.id, key: "g:toolu_agent", true)
        rig.start()
        XCTAssertTrue(rig.followTail.isPinned)
        let group = try XCTUnwrap(rig.groupView(turn: tail.id, key: "g:toolu_agent"))
        let activity = try XCTUnwrap(group.memberViews.first { $0 is AgentActivityView }, "the Agent call has subagent activity")
        let before = rig.screenY(of: activity)
        XCTAssertGreaterThan(before, 0, "precondition: the activity row is on screen")
        XCTAssertLessThan(before, rig.viewportHeight)

        // Open the activity.
        try XCTUnwrap(disclosureButton(in: activity)).performClick(nil)
        rig.runPass()
        XCTAssertEqual(rig.screenY(of: activity), before, accuracy: 1, "opening the activity moved its row")

        // Then a subagent result inside it: its block index is a subagent block, not a member.
        let result = try XCTUnwrap(rigAllSubviews(of: activity).compactMap { $0 as? ToolResultView }.first,
                                   "the activity lists the subagent's result")
        let button = try XCTUnwrap(disclosureButton(in: result))
        button.performClick(nil)
        rig.runPass()

        XCTAssertTrue(button.title.hasPrefix("▼"), "precondition: the subagent result opened")
        XCTAssertEqual(rig.screenY(of: activity), before, accuracy: 1, "the activity row moved when a result inside it opened")
    }
}


// MARK: - Focus: roll-ins, holds and activity rows (FV2)

private func focusMessage(_ tag: String) -> TurnBlock { .text("\(tag) \(F.prose) \(F.prose)") }

/// An activity row (`opening` and one group of three calls) above a tall latest message.
private func activityTurn(_ n: Int) -> ChatTurn {
    F.turn([focusMessage("Act \(n) opening")] + F.run(3, prefix: "A\(n)_") + fillerBlocks(10, tag: "act \(n)"),
           user: "activity \(n)")
}

final class FocusScrollTests: XCTestCase {

    private func textBlock(containing text: String, in view: ChatTurnView?) -> TextBlockView? {
        view?.subviews.compactMap { $0 as? TextBlockView }.first { FocusFixtures.contains(text, in: $0) }
    }

    // MARK: following

    func testAFollowingPaneStaysAtTheTrueBottomThroughTenRollIns() throws {
        let live = F.turn([focusMessage("Starting")], complete: false, user: "go")
        let rig = ScrollRig(self, turns: (0 ..< 4).map(longTurn) + [live])
        rig.start()
        XCTAssertTrue(rig.followTail.isPinned)
        XCTAssertLessThanOrEqual(rig.gapBelowViewport, 0.5)

        for n in 0 ..< 10 {
            rig.append(F.run(2, prefix: "r\(n)_"))
            XCTAssertLessThanOrEqual(rig.gapBelowViewport, 0.5, "after the calls of step \(n)")
            rig.append([focusMessage("Message \(n)")])

            XCTAssertLessThanOrEqual(rig.gapBelowViewport, 0.5, "after roll-in \(n) the viewport ends at the true bottom")
            XCTAssertTrue(rig.followTail.isPinned, "after roll-in \(n)")
        }

        let view = try XCTUnwrap(rig.materialized[live.id])
        XCTAssertEqual(view.activityRowViews.count, 1)
        XCTAssertTrue(view.activityRowViews[0].row.summaryField.stringValue.hasPrefix("10 messages"),
                      view.activityRowViews[0].row.summaryField.stringValue)
        XCTAssertTrue(rig.holds.isEmpty, "a following pane never holds a roll-in")
        XCTAssertTrue(rig.flips.filter { !$0.pinned }.isEmpty, "following never stopped")
    }

    // MARK: not following: the interim hold

    private func holdingRig() -> (ScrollRig, ChatTurn) {
        // The outgoing message is three text blocks tall, so it is on screen however the geometry rounds.
        let live = F.turn([focusMessage("Earlier note")] + F.run(2, prefix: "a")
                          + [focusMessage("OLD-HELD-MSG"), focusMessage("OLD-HELD-TWO"), focusMessage("OLD-HELD-THREE")]
                          + F.run(2, prefix: "b"), complete: false, user: "live")
        let rig = ScrollRig(self, turns: (0 ..< 4).map(longTurn) + [live])
        rig.start()
        rig.userScroll(to: rig.doc.frame.height - rig.viewportHeight - 60)
        rig.settle()
        return (rig, live)
    }

    func testANonFollowingPaneHoldsTheOutgoingMessageWhereTheReaderSeesItAndNothingMoves() throws {
        let (rig, live) = holdingRig()
        XCTAssertFalse(rig.followTail.isPinned, "precondition: the operator is reading")
        let old = try XCTUnwrap(textBlock(containing: "OLD-HELD-MSG", in: rig.materialized[live.id]))
        let y = rig.screenY(of: old)
        XCTAssertGreaterThanOrEqual(y + old.bounds.height, 0, "precondition: the outgoing message is on screen")
        XCTAssertLessThan(y, rig.viewportHeight, "precondition: the outgoing message is on screen")
        let probe = try XCTUnwrap(rig.probe())

        rig.append([focusMessage("NEW-LATEST-MSG")])

        XCTAssertEqual(rig.holds, [1], "the second message (ordinal 1) was held")
        XCTAssertEqual(rig.store.state(for: live.id).heldOrdinals, [1])
        assertStill(rig, probe, "after a roll-in was held")
        let view = try XCTUnwrap(rig.materialized[live.id])
        XCTAssertTrue(textBlock(containing: "OLD-HELD-MSG", in: view) === old, "the old message's view is still in the tree, untouched")
        XCTAssertNotNil(textBlock(containing: "NEW-LATEST-MSG", in: view), "the newer message appears below as the latest")
        XCTAssertEqual(rig.screenY(of: old), y, accuracy: 1, "the held message did not move")
        XCTAssertFalse(rig.followTail.isPinned)
    }

    func testJumpToLatestReleasesTheHoldFoldsTheMessageIntoTheRowAndLandsAtTheTrueBottom() throws {
        let (rig, live) = holdingRig()
        rig.append([focusMessage("NEW-LATEST-MSG")])
        XCTAssertEqual(rig.holds, [1], "precondition: the roll-in was held")
        rig.flips = []

        rig.followTail.pinToBottomAndScroll(cause: .jumpToLatest)   // what the overlay's button does
        rig.settle()

        XCTAssertTrue(rig.followTail.isPinned)
        XCTAssertEqual(rig.flips.map(\.cause), [.jumpToLatest])
        XCTAssertLessThanOrEqual(rig.gapBelowViewport, 0.5, "the pane is at the true bottom")
        XCTAssertTrue(rig.store.state(for: live.id).heldOrdinals.isEmpty, "the hold is released")
        let view = try XCTUnwrap(rig.materialized[live.id])
        XCTAssertNil(textBlock(containing: "OLD-HELD-MSG", in: view), "no top-level text block still holds the old message")
        XCTAssertNotNil(textBlock(containing: "NEW-LATEST-MSG", in: view))
        XCTAssertTrue(try XCTUnwrap(view.activityRowViews.first).row.summaryField.stringValue.hasPrefix("2 messages"),
                      "the old message is in the row")
    }

    func testAHoldSurvivesTheViewBeingRebuiltWhileTheOperatorIsStillReading() throws {
        let (rig, live) = holdingRig()
        rig.append([focusMessage("NEW-LATEST-MSG")])
        let probe = try XCTUnwrap(rig.probe())

        for view in rig.materialized.values { view.removeFromSuperview() }
        rig.materialized.removeAll()
        rig.runPass()

        XCTAssertNotNil(textBlock(containing: "OLD-HELD-MSG", in: rig.materialized[live.id]), "rebuilt, the held message is still conversation")
        assertStill(rig, probe, "after the views were rebuilt")
    }

    // MARK: toggling an activity row

    func testTogglingAnActivityRowNearTheBottomOfAPinnedPaneKeepsItsRowStill() throws {
        let tail = F.turn([focusMessage("Tail opening")] + F.run(3, prefix: "g") + [.text("Tail closing line.")], user: "tail")
        let rig = ScrollRig(self, turns: (0 ..< 4).map(longTurn) + [tail])
        rig.start()
        XCTAssertTrue(rig.followTail.isPinned)
        let activity = try XCTUnwrap(rig.materialized[tail.id]?.activityRowViews.first)
        let key = activity.segment.key
        let before = rig.screenY(of: activity.row)
        XCTAssertGreaterThan(before, 0, "precondition: the row is on screen")
        XCTAssertLessThan(before, rig.viewportHeight)

        rig.toggleActivityRow(turn: tail.id, key: key)

        XCTAssertEqual(rig.activityToggles, ["\(key)=true"])
        XCTAssertTrue(activity.isExpanded)
        XCTAssertEqual(rig.screenY(of: activity.row), before, accuracy: 1, "expanding moved the row")

        rig.toggleActivityRow(turn: tail.id, key: key)

        XCTAssertEqual(rig.activityToggles, ["\(key)=true", "\(key)=false"])
        XCTAssertEqual(rig.screenY(of: activity.row), before, accuracy: 1, "collapsing moved the row")
    }

    func testTogglingAnActivityRowWhileScrolledUpKeepsItsRowStill() throws {
        let rig = ScrollRig(self, turns: (0 ..< 6).map(activityTurn))
        rig.start()
        let target = rig.turns[3].id
        let key = try XCTUnwrap(FocusFixtures.segments(of: rig.turns[3]).first).key
        let placed = try XCTUnwrap(rig.placeActivityRow(turn: target, key: key, atScreenY: 150))
        XCTAssertEqual(placed, 150, accuracy: 2)
        XCTAssertFalse(rig.followTail.isPinned)
        let row = try XCTUnwrap(rig.activityRow(turn: target, key: key)).row
        let collapsedHeight = rig.virtualizer.height(at: 3)

        rig.toggleActivityRow(turn: target, key: key)

        XCTAssertGreaterThan(rig.virtualizer.height(at: 3), collapsedHeight + 30, "precondition: the row opened")
        XCTAssertEqual(rig.screenY(of: row), placed, accuracy: 1, "expanding moved the row")

        rig.toggleActivityRow(turn: target, key: key)

        XCTAssertEqual(rig.virtualizer.height(at: 3), collapsedHeight, accuracy: 1)
        XCTAssertEqual(rig.screenY(of: row), placed, accuracy: 1, "collapsing moved the row")
    }

    // MARK: an open row through a roll-in

    private func openLaneTail() -> ChatTurn {
        var blocks: [TurnBlock] = []
        for i in 0 ..< 16 { blocks += [focusMessage("LANE-\(i)")] + F.run(1, prefix: "l\(i)_") }
        blocks.append(focusMessage("OLDEST-LATEST-MSG"))
        return F.turn(blocks, complete: false, user: "open lane")
    }

    func testAnExpandedRowThatAbsorbsARollInStaysOpenAndTheFirstVisibleLineDoesNotMove() throws {
        let tail = openLaneTail()
        let rig = ScrollRig(self, turns: (0 ..< 3).map(longTurn) + [tail])
        rig.store.setActivity(turn: tail.id, key: FocusFixtures.segments(of: tail)[0].key, true)
        rig.start()
        let tailIndex = rig.turns.count - 1
        rig.userScroll(to: rig.virtualizer.offset(of: tailIndex) + 300)
        rig.settle()
        XCTAssertFalse(rig.followTail.isPinned, "precondition: the operator is reading inside the open lane")
        let activity = try XCTUnwrap(rig.materialized[tail.id]?.activityRowViews.first)
        XCTAssertTrue(activity.isExpanded, "precondition")
        let member = try XCTUnwrap(activity.laneMemberViews.first { (20 ..< 400).contains(rig.screenY(of: $0)) },
                                   "precondition: a lane member is on screen")
        let before = rig.screenY(of: member)
        let probe = try XCTUnwrap(rig.probe())
        rig.holdPolicy = { false }   // off screen roll-ins go through (FV3's rule); this is the layout half

        // A note between, so it is a newer message (contract §2.1) and nothing trails the old one.
        rig.append([.note("Model changed to Opus."), focusMessage("NEWER-MSG")])

        XCTAssertTrue(rig.holds.isEmpty)
        XCTAssertTrue(activity.isExpanded, "an open row stays open")
        XCTAssertTrue(FocusFixtures.contains("OLDEST-LATEST-MSG", in: try XCTUnwrap(activity.laneMemberViews.last)),
                      "the rolled-in message is at the end of the lane")
        XCTAssertEqual(rig.screenY(of: member), before, accuracy: 1, "a lane member moved")
        assertStill(rig, probe, "after the open row absorbed a roll-in")
        XCTAssertFalse(rig.followTail.isPinned)
    }

    func testAnExpandedRowInAFollowingPaneStaysOpenAndThePaneStaysAtTheBottom() throws {
        let live = F.turn([focusMessage("First")] + F.run(2, prefix: "a") + [focusMessage("Second")], complete: false, user: "live")
        let rig = ScrollRig(self, turns: (0 ..< 4).map(longTurn) + [live])
        rig.store.setActivity(turn: live.id, key: FocusFixtures.segments(of: live)[0].key, true)
        rig.start()
        XCTAssertTrue(rig.followTail.isPinned)

        for n in 0 ..< 3 {
            rig.append(F.run(1, prefix: "roll\(n)_") + [focusMessage("Roll \(n)")])

            XCTAssertLessThanOrEqual(rig.gapBelowViewport, 0.5, "after roll-in \(n)")
            XCTAssertEqual(rig.materialized[live.id]?.activityRowViews.first?.isExpanded, true, "after roll-in \(n)")
        }
    }

    // MARK: layout cost, across the pane

    func testARollInMeasuresOnlyItsOwnTurnsIslandsAcrossThePane() throws {
        let live = F.turn([focusMessage("First")] + F.run(2, prefix: "a") + [focusMessage("Second")] + F.run(1, prefix: "b"),
                          complete: false, user: "live")
        let rig = ScrollRig(self, turns: (0 ..< 6).map(historyTurn) + [live])
        rig.start()
        let others = rig.materialized.filter { $0.key != live.id }
        XCTAssertGreaterThan(others.count, 0, "precondition: other turns are materialized in the pane")
        let otherViews = others.mapValues { ObjectIdentifier($0) }

        ChatTurnView.measureIslandCount = 0
        rig.append([focusMessage("Third")])   // rolls Second and group b into the row

        let view = try XCTUnwrap(rig.materialized[live.id])
        XCTAssertEqual(view.activityRowViews.first?.row.summaryField.stringValue.hasPrefix("2 messages"), true,
                       "precondition: the roll-in happened")
        XCTAssertGreaterThan(ChatTurnView.measureIslandCount, 0)
        XCTAssertLessThanOrEqual(ChatTurnView.measureIslandCount, view.subviews.count,
                                 "no more measurements than the rolled-in turn has islands")
        for (id, identity) in otherViews {
            XCTAssertEqual(rig.materialized[id].map { ObjectIdentifier($0) }, identity, "another turn's view was rebuilt")
        }
    }

    // MARK: the composer

    func testTheComposerKeepsFirstResponderThroughRollIns() throws {
        let live = F.turn([focusMessage("First")], complete: false, user: "live")
        let rig = ScrollRig(self, turns: (0 ..< 4).map(longTurn) + [live])
        rig.start()
        let composer = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 40))
        rig.window.contentView!.addSubview(composer)
        XCTAssertTrue(rig.window.makeFirstResponder(composer))

        for n in 0 ..< 5 {
            rig.append(F.run(2, prefix: "c\(n)_"))
            rig.append([focusMessage("Message \(n)")])
            XCTAssertTrue(rig.window.firstResponder === composer,
                          "roll-in \(n) took focus: \(String(describing: rig.window.firstResponder))")
        }
        XCTAssertEqual(rig.materialized[live.id]?.activityRowViews.count, 1)
    }
}
