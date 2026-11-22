// T1w: the transcript keeps its first visible block across a width change (the tracker's first open
// narrows it once; a window resize or a divider drag does the same).
import XCTest
import AppKit

/// The rig's half of `ReplView.layout()`'s width branch: the coordinator names the reading position
/// at the old width, the virtualizer re-estimates, every view is released, a pass runs.
extension SafetyRig {
    /// `settle`: run the pass now (a window resize); false leaves it to the caller (a drag in flight).
    func changeWidth(to width: CGFloat, settle runNow: Bool = true) {
        coordinator.noteWidthChange()
        contentWidth = width
        virtualizer.invalidateWidth(width, turns: turns)
        for view in materialized.values { view.removeFromSuperview() }
        materialized.removeAll()
        pending.removeAll()
        guard runNow else { return }
        runPass()
        settle()
    }
}

final class TranscriptWidthAnchorTests: XCTestCase {

    private let widths: [CGFloat] = [880, 880 * 0.66, 880 * 0.5, 880]

    /// Block indexes: 0 opening prose, 1...8 a group of four calls, 9...14 prose, 15 a fenced code
    /// block, 16...21 prose.
    private static func turn(_ n: Int) -> ChatTurn {
        let prose = (0 ..< 6).map {
            TurnBlock.text("turn \(n) paragraph \($0). \(FoldFixtures.prose) \(FoldFixtures.prose) \(FoldFixtures.prose) \(FoldFixtures.prose)")
        }
        let code = (0 ..< 30).map { "let value\($0) = compute(\($0)) // line \($0) of the snippet" }.joined(separator: "\n")
        return FoldFixtures.turn([.text("Turn \(n) opening. \(FoldFixtures.prose)")]
                                 + FoldFixtures.run(4, prefix: "w\(n)_") + prose
                                 + [.text("```swift\n\(code)\n```")] + prose,
                                 user: "turn \(n)")
    }

    private func makeRig() -> SafetyRig {
        let rig = SafetyRig(self, turns: (0 ..< 8).map(Self.turn) + [FoldFixtures.turn([.text("Tail.")], user: "tail")])
        rig.start()
        return rig
    }

    /// The body font's line height, measured.
    private var lineHeight: CGFloat { NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: 13)) }

    private enum Spot { case prose, group, code }

    /// Scroll up into turn 3 so the viewport top sits `into` points inside the `spot` item.
    private func park(_ rig: SafetyRig, at spot: Spot, into: CGFloat) {
        rig.userScroll(to: rig.virtualizer.offset(of: 3))
        rig.followTail.setPinned(false, cause: .harness)
        rig.settle()
        guard let island = rig.materialized[rig.turns[3].id] else { return XCTFail("turn 3 is not materialized") }
        let key: String
        switch spot {
        case .prose: key = "b10"
        case .code: key = "b15"
        case .group:
            var found: String?
            var y: CGFloat = 0
            while found == nil, y < island.frame.height {
                if let item = island.anchorItem(atY: y), !item.key.hasPrefix("b") { found = item.key }
                y += 2
            }
            guard let group = found else { return XCTFail("no tool group in turn 3") }
            key = group
        }
        guard let top = island.offset(ofItemKey: key) else { return XCTFail("no item \(key) in turn 3") }
        rig.userScroll(to: rig.virtualizer.offset(of: 3) + top + into)
        rig.followTail.setPinned(false, cause: .harness)
        rig.settle()
        rig.focusComposer()
        XCTAssertEqual(rig.snapshot().firstVisible?.itemKey, key, "setup anchors in \(key)")
    }

    /// Resize through `widths`, comparing what the operator sees at each step.
    private func assertAnchored(_ name: String, spot: Spot, into: CGFloat) {
        let rig = makeRig()
        park(rig, at: spot, into: into)
        var worst: CGFloat = 0
        for width in widths.dropFirst() {
            let before = rig.snapshot()
            let turnBefore = rig.firstVisibleTurnIdentity()
            let barBefore = rig.inputBar.frame.height
            let responder = rig.window.firstResponder
            rig.changeWidth(to: width)
            let after = rig.snapshot()
            XCTAssertEqual(rig.firstVisibleTurnIdentity(), turnBefore, "\(name) @\(width): first visible turn changed")
            XCTAssertEqual(after.firstVisible?.itemKey, before.firstVisible?.itemKey, "\(name) @\(width): first visible item changed")
            let drift = abs(CGFloat(after.firstVisible?.offsetPt ?? .infinity) - CGFloat(before.firstVisible?.offsetPt ?? 0))
            worst = max(worst, drift)
            XCTAssertLessThanOrEqual(drift, lineHeight, "\(name) @\(width): anchored item moved \(drift) pt (line \(lineHeight))")
            XCTAssertEqual(rig.inputBar.frame.height, barBefore, accuracy: 0.5, "\(name): input bar height")
            XCTAssertTrue(rig.window.firstResponder === responder, "\(name): first responder")
            XCTAssertEqual(rig.textView.string, SafetyRig.typedText, "\(name): composer text")
            XCTAssertEqual(rig.textView.selectedRange(), SafetyRig.typedSelection, "\(name): composer selection")
            XCTAssertFalse(rig.followTail.isPinned, "\(name): still reading, not following")
        }
        print("T1W worst error \(name): \(worst) pt (line height \(lineHeight))")
    }

    func testAProseParagraphKeepsItsPlaceAcrossEveryWidthChange() { assertAnchored("prose", spot: .prose, into: 20) }

    func testAToolGroupRowKeepsItsPlaceAcrossEveryWidthChange() { assertAnchored("group", spot: .group, into: 6) }

    func testACodeBlockKeepsItsPlaceAcrossEveryWidthChange() { assertAnchored("code", spot: .code, into: 80) }

    func testAFollowingTranscriptStaysAtTheBottomAcrossEveryWidthChange() {
        let rig = makeRig()
        rig.focusComposer()
        XCTAssertTrue(rig.followTail.isPinned)
        for width in widths.dropFirst() {
            // One pass, not `settle`: a later pass would follow the tail on its own, and the width
            // change's own pass has to land at the bottom.
            rig.changeWidth(to: width, settle: false)
            rig.runPass()
            XCTAssertEqual(rig.snapshot().bottomOffsetPt, 0, accuracy: 0.5, "@\(width): at the bottom after the pass")
            XCTAssertTrue(rig.followTail.isPinned, "@\(width): still following")
            XCTAssertEqual(rig.textView.string, SafetyRig.typedText)
            XCTAssertEqual(rig.textView.selectedRange(), SafetyRig.typedSelection)
        }
    }

    func testADividerDragOfTenWidthChangesEndsOnTheSameFirstVisibleTurn() {
        let rig = makeRig()
        park(rig, at: .prose, into: 20)
        let turnBefore = rig.firstVisibleTurnIdentity()
        let itemBefore = rig.snapshot().firstVisible?.itemKey
        for step in 1 ... 5 { rig.changeWidth(to: 880 - CGFloat(step) * 48) }
        for step in 1 ... 5 { rig.changeWidth(to: 880 - 240 + CGFloat(step) * 48) }
        XCTAssertEqual(rig.contentWidth, 880)
        XCTAssertEqual(rig.firstVisibleTurnIdentity(), turnBefore)
        XCTAssertEqual(rig.snapshot().firstVisible?.itemKey, itemBefore)
    }

    func testTwoWidthChangesBeforeAPassKeepTheFirstCapture() {
        let rig = makeRig()
        park(rig, at: .prose, into: 20)
        let turnBefore = rig.firstVisibleTurnIdentity()
        rig.changeWidth(to: 700, settle: false)
        rig.changeWidth(to: 600)   // a second change before any pass ran
        XCTAssertEqual(rig.firstVisibleTurnIdentity(), turnBefore)
    }

    // MARK: Review leftovers from #494

    /// AppKit clamps the clip's origin itself when the document is resized, before the pass runs. The
    /// rig does not resize the document until the pass, so the test makes that move by hand.
    func testTheWidthPassKeepsTheCapturedPositionEvenThoughAppKitMovedTheClipOriginBeforeIt() {
        let rig = makeRig()
        park(rig, at: .prose, into: 20)
        let before = rig.snapshot()
        let turnBefore = rig.firstVisibleTurnIdentity()
        rig.changeWidth(to: 880 * 0.66, settle: false)
        let origin = rig.clip.bounds.minY
        rig.userScroll(to: origin + 30)   // what the clamp does; not the operator
        XCTAssertEqual(rig.clip.bounds.minY, origin + 30, accuracy: 0.5, "setup: the origin moved before the pass")
        rig.runPass()
        rig.settle()
        let after = rig.snapshot()
        XCTAssertEqual(rig.firstVisibleTurnIdentity(), turnBefore)
        XCTAssertEqual(after.firstVisible?.itemKey, before.firstVisible?.itemKey)
        let drift = abs(CGFloat(after.firstVisible?.offsetPt ?? .infinity) - CGFloat(before.firstVisible?.offsetPt ?? 0))
        XCTAssertLessThanOrEqual(drift, TranscriptViewportCoordinator.widthAnchorTolerance + 1,
                                 "the pass restored the captured position (\(drift) pt off), not the clamped one 30 pt below it")
    }

    /// The same window, for a pane that was following the tail: the operator scrolls up before the pass.
    func testAnOperatorWhoScrollsUpBetweenAWidthChangeAndItsPassIsNotPulledBackToTheBottom() {
        let rig = makeRig()
        rig.focusComposer()
        XCTAssertTrue(rig.followTail.isPinned)
        rig.changeWidth(to: 880 * 0.66, settle: false)
        rig.userScroll(to: rig.virtualizer.offset(of: 3))
        rig.followTail.setPinned(false, cause: .userScroll)
        rig.runPass()
        XCTAssertFalse(rig.followTail.isPinned, "the operator stopped following; the pass does not turn it back on")
        XCTAssertGreaterThan(rig.snapshot().bottomOffsetPt, rig.viewportHeight, "and the view is far from the bottom, not pulled down (it is not held at the exact spot: see the PR notes)")
    }

    /// The restore puts the line on the side of its old offset that its fraction of the item's new height
    /// says, within the tolerance. A restore that ignored the fraction would always land half a line above.
    func testTheRestoredOffsetFollowsTheFractionOfTheItemsNewHeightWithinTheTolerance() throws {
        let rig = makeRig()
        park(rig, at: .prose, into: 6)   // shallow, so the fraction lands inside the band, not on its edge
        let turn = rig.turns[3]
        func height(of key: String) throws -> CGFloat {
            let island = try XCTUnwrap(rig.materialized[turn.id])
            let top = try XCTUnwrap(island.offset(ofItemKey: key))
            var low = top, high = island.frame.height
            for _ in 0 ..< 24 {
                let mid = (low + high) / 2
                if island.anchorItem(atY: mid)?.key == key { low = mid } else { high = mid }
            }
            return high - top
        }
        let oldHeight = try height(of: "b10")
        let oldOffset = CGFloat(try XCTUnwrap(rig.snapshot().firstVisible?.offsetPt))
        rig.changeWidth(to: 880 * 0.66)
        let newHeight = try height(of: "b10")
        let tolerance = TranscriptViewportCoordinator.widthAnchorTolerance
        let expected = min(max(oldOffset / oldHeight * newHeight, oldOffset - tolerance), oldOffset + tolerance)
        let after = CGFloat(try XCTUnwrap(rig.snapshot().firstVisible?.offsetPt))
        for (name, edge) in [("the old offset", oldOffset), ("the band's lower edge", max(0, oldOffset - tolerance)), ("the band's upper edge", oldOffset + tolerance)] {
            XCTAssertNotEqual(expected, edge, accuracy: 1, "setup: the fraction decides here (inside the band), so a restore that used \(name) is visible")
        }
        XCTAssertEqual(rig.snapshot().firstVisible?.itemKey, "b10", "still in the same item")
        XCTAssertEqual(after, expected, accuracy: 1, "old \(oldOffset) of \(oldHeight), new height \(newHeight)")
    }
}
