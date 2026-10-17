import XCTest
import AppKit
import NostromoKit

// BA2: the `transcript-anchor` probe (pure geometry) and the scroll-safety gate's own self-test.

final class TranscriptAnchorProbeTests: XCTestCase {

    private let clip = CGRect(x: 0, y: 1000, width: 900, height: 600)

    private func snap(_ anchor: TurnListVirtualizer.Anchor?, clip: CGRect? = nil, documentHeight: CGFloat = 5000,
                      following: Bool = false) -> TranscriptAnchorSnapshot {
        TranscriptAnchorProbe.snapshot(tag: "kate", window: 1, clipBounds: clip ?? self.clip,
                                       documentHeight: documentHeight, anchor: anchor, following: following)
    }

    func testAnchorInsideATurnWithNoItemReportsTheTurnOffset() {
        let s = snap(.init(key: "turn-7", index: 7, offsetWithinTurn: 120))
        XCTAssertEqual(s.tag, "kate")
        XCTAssertEqual(s.window, 1)
        XCTAssertEqual(s.firstVisible, .init(turnKey: "turn-7", itemKey: nil, offsetPt: 120))
    }

    func testAnchorInsideAnItemReportsTheItemOffsetNotTheTurnOffset() {
        let s = snap(.init(key: "turn-7", index: 7, offsetWithinTurn: 340, itemKey: "g:s7_0", offsetInItem: 18))
        XCTAssertEqual(s.firstVisible, .init(turnKey: "turn-7", itemKey: "g:s7_0", offsetPt: 18))
    }

    func testAnchorAtTheVeryTopIsZero() {
        let top = CGRect(x: 0, y: 0, width: 900, height: 600)
        let s = snap(.init(key: "turn-0", index: 0, offsetWithinTurn: 0, itemKey: "b0", offsetInItem: 0), clip: top)
        XCTAssertEqual(s.firstVisible?.offsetPt, 0)
        XCTAssertEqual(s.bottomOffsetPt, 4400)
    }

    func testAViewportTopInTheSpaceAboveAnItemNeverReportsANegativeOffset() {
        let s = snap(.init(key: "turn-2", index: 2, offsetWithinTurn: 4, itemKey: "b0", offsetInItem: -6))
        XCTAssertEqual(s.firstVisible?.offsetPt, 0)
    }

    func testAtTheBottomTheBottomOffsetIsZeroAndTheFollowFlagIsPassedThrough() {
        let bottom = CGRect(x: 0, y: 4400, width: 900, height: 600)
        let s = snap(.init(key: "t", index: 1, offsetWithinTurn: 3), clip: bottom, following: true)
        XCTAssertEqual(s.bottomOffsetPt, 0)
        XCTAssertTrue(s.following)
    }

    func testBottomOffsetIsTheGapBelowTheViewport() {
        XCTAssertEqual(snap(.init(key: "t", index: 1, offsetWithinTurn: 3)).bottomOffsetPt, 3400)
    }

    func testADocumentShorterThanTheViewportIsAtTheBottom() {
        let s = snap(nil, clip: CGRect(x: 0, y: 0, width: 900, height: 600), documentHeight: 200)
        XCTAssertEqual(s.bottomOffsetPt, 0)
    }

    func testAnEmptyTranscriptHasNoFirstVisibleBlock() {
        XCTAssertNil(snap(nil).firstVisible)
    }

    func testTheJSONShapeIsStableAndEmptyIsExplicitNull() throws {
        let data = try JSONEncoder().encode(snap(nil, following: true))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["tag", "window", "firstVisible", "bottomOffsetPt", "following"])
        XCTAssertTrue(json["firstVisible"] is NSNull)

        let withItem = try JSONEncoder().encode(snap(.init(key: "k", index: 0, offsetWithinTurn: 1)))
        let fv = try XCTUnwrap((try JSONSerialization.jsonObject(with: withItem) as? [String: Any])?["firstVisible"] as? [String: Any])
        XCTAssertEqual(Set(fv.keys), ["turnKey", "itemKey", "offsetPt"])
        XCTAssertTrue(fv["itemKey"] is NSNull)
        XCTAssertEqual(try JSONDecoder().decode(TranscriptAnchorSnapshot.self, from: withItem),
                       snap(.init(key: "k", index: 0, offsetWithinTurn: 1)))
    }
}

// MARK: - The gate proves itself

final class ScrollSafetyGateSelfTests: XCTestCase {

    func testANoOpPassesWhileFollowingTheTail() {
        let rig = SafetyRig.followingTail(self)
        rig.assertNoMove("no-op", following: true) {}
    }

    func testANoOpPassesWhileScrolledUp() {
        let rig = SafetyRig.scrolledUp(self)
        rig.assertNoMove("no-op", following: false) {}
    }

    func testTheSetupsHoldTheComposerStateTheGateAsserts() {
        for rig in [SafetyRig.followingTail(self), SafetyRig.scrolledUp(self)] {
            XCTAssertTrue(rig.window.firstResponder === rig.textView)
            XCTAssertEqual(rig.textView.string, SafetyRig.typedText)
            XCTAssertEqual(rig.textView.selectedRange(), SafetyRig.typedSelection)
        }
        XCTAssertLessThanOrEqual(SafetyRig.followingTail(self).snapshot().bottomOffsetPt, 0.5)
        XCTAssertGreaterThan(SafetyRig.scrolledUp(self).snapshot().bottomOffsetPt, 100)
    }

    func testATwentyPointInputBarChangeFailsTheScrolledUpGate() {
        let rig = SafetyRig.scrolledUp(self)
        XCTExpectFailure("a 20 pt input bar change shrinks the clip and must trip the gate") {
            rig.assertNoMove("bar +20", following: false) {
                rig.barHeight.constant += 20
                rig.window.contentView?.layoutSubtreeIfNeeded()
            }
        }
    }

    func testATwentyPointInputBarChangeFailsTheFollowingGate() {
        let rig = SafetyRig.followingTail(self)
        XCTExpectFailure("a 20 pt input bar change must trip the gate") {
            rig.assertNoMove("bar +20", following: true) {
                rig.barHeight.constant += 20
                rig.window.contentView?.layoutSubtreeIfNeeded()
            }
        }
    }

    func testAChangedComposerFailsTheGate() {
        let rig = SafetyRig.scrolledUp(self)
        XCTExpectFailure("changed composer text and selection must trip the gate") {
            rig.assertNoMove("typing", following: false) {
                rig.textView.string = "something else"
                rig.textView.setSelectedRange(NSRange(location: 0, length: 0))
            }
        }
    }

    func testStolenFocusFailsTheGate() {
        let rig = SafetyRig.scrolledUp(self)
        XCTExpectFailure("a focus steal must trip the gate") {
            rig.assertNoMove("focus", following: false) { _ = rig.window.makeFirstResponder(nil) }
        }
    }

    func testAScrollOfTwentyPointsFailsTheScrolledUpGate() {
        let rig = SafetyRig.scrolledUp(self)
        XCTExpectFailure("moving the transcript 20 pt must trip the gate") {
            rig.assertNoMove("scroll", following: false) { rig.userScroll(to: rig.clip.bounds.minY + 20) }
        }
    }

    // MARK: The 1 pt tolerance

    /// Put the viewport top 2 pt into the first text block of turn `index`, so the first visible block
    /// is that block and a plain scroll moves its offset by exactly the scroll distance.
    private func scrollIntoFirstBlock(of rig: SafetyRig, turn index: Int) throws {
        let view = try XCTUnwrap(rig.materialized[rig.turns[index].id], "the turn is built")
        let block = try XCTUnwrap(view.subviews.compactMap { $0 as? TextBlockView }.first, "the turn opens with a text block")
        rig.userScroll(to: rig.doc.convert(block.bounds, from: block).minY + 2)
        rig.settle()
        XCTAssertFalse(rig.followTail.isPinned, "precondition: the pane is not following")
    }

    func testAScrollOfExactlyOnePointPassesTheScrolledUpGate() throws {
        let rig = SafetyRig.scrolledUp(self)
        try scrollIntoFirstBlock(of: rig, turn: 3)
        // The first visible block stays the same block; its offset changes by the scroll distance.
        rig.assertNoMove("scroll 1.0", following: false) { rig.userScroll(to: rig.clip.bounds.minY + 1.0) }
    }

    func testAScrollOfOneAndAHalfPointsFailsTheScrolledUpGate() throws {
        let rig = SafetyRig.scrolledUp(self)
        try scrollIntoFirstBlock(of: rig, turn: 3)
        XCTExpectFailure("1.5 pt is past the 1 pt tolerance") {
            rig.assertNoMove("scroll 1.5", following: false) { rig.userScroll(to: rig.clip.bounds.minY + 1.5) }
        }
    }

    // MARK: Following the tail

    func testAMoveWhileFollowingTheTailFailsTheFollowingGate() {
        let rig = SafetyRig.followingTail(self)
        XCTExpectFailure("scrolling up 40 pt leaves the true bottom (and stops following)") {
            rig.assertNoMove("scroll up 40", following: true) { rig.userScroll(to: rig.clip.bounds.minY - 40) }
        }
    }

    // MARK: Streaming into the turn at the top of the viewport

    /// A pane scrolled into the first block of turn 3, which is still running (incomplete), composer focused.
    private func streamingAtTheTop() throws -> SafetyRig {
        var turns = SafetyFixtures.transcript()
        turns[3].isComplete = false
        let rig = SafetyRig(self, turns: turns)
        rig.start()
        rig.userScroll(to: rig.virtualizer.offset(of: 3) + 40)
        rig.followTail.setPinned(false, cause: .harness)
        rig.settle()
        rig.focusComposer()
        try scrollIntoFirstBlock(of: rig, turn: 3)
        XCTAssertEqual(rig.firstVisibleTurnIdentity(), turns[3].identityKey, "precondition: the viewport top is in the running turn")
        return rig
    }

    func testStreamingABlockIntoTheTurnAtTheTopOfTheViewportPassesTheGate() throws {
        let rig = try streamingAtTheTop()
        let turnKeyBefore = rig.snapshot().firstVisible?.turnKey

        rig.assertNoMove("stream into the top turn", following: false) {
            rig.append([.text("A streamed paragraph. \(FoldFixtures.prose)")], toTurnAt: 3)
        }

        // The content key of the turn changed with the append (the reason the gate compares the
        // turn's durable identity), and the gate still held.
        XCTAssertNotEqual(rig.snapshot().firstVisible?.turnKey, turnKeyBefore, "precondition: the append changed the turn")
    }

    func testStreamingIntoTheTurnAtTheTopWhileTheViewportMovesStillFailsTheGate() throws {
        let rig = try streamingAtTheTop()
        XCTExpectFailure("the viewport moved 20 pt in the same event") {
            rig.assertNoMove("stream and scroll", following: false) {
                rig.append([.text("A streamed paragraph. \(FoldFixtures.prose)")], toTurnAt: 3)
                rig.userScroll(to: rig.clip.bounds.minY + 20)
            }
        }
    }

    // MARK: A roll-in at the tail of a following pane

    func testARollInAtTheTailOfAFollowingPaneKeepsTheBottomAndTheComposerThoughTheTopLineMoves() {
        // `assertNoMove` does not apply here, and that is correct, not a gap in the gate: it also
        // compares the first visible block. A following pane keeps the bottom, so when the roll-in
        // folds the old message (and the calls after it) into one row and the new message is shorter,
        // the turn shrinks and the line at the top of the viewport is a different, earlier one. What
        // must hold is what the operator is promised: the bottom, still following, the composer.
        let message = (0 ..< 6).map { TurnBlock.text("HELD-\($0) \(FoldFixtures.prose) \(FoldFixtures.prose) \(FoldFixtures.prose)") }
        let live = FoldFixtures.turn([focusMessage("Earlier")] + FoldFixtures.run(2, prefix: "a") + message
                                     + FoldFixtures.run(2, prefix: "b"), complete: false, user: "live")
        let rig = SafetyRig(self, turns: (0 ..< 4).map { SafetyFixtures.tallTurn($0) } + [live])
        rig.start()
        rig.focusComposer()
        XCTAssertTrue(rig.followTail.isPinned, "precondition: the pane follows the tail")
        let bar = rig.inputBar.frame.height
        let scrollFrame = rig.composerScroll?.frame

        rig.append(FoldFixtures.run(1, prefix: "call-next-") + [focusMessage("NEXT-MSG")])

        XCTAssertTrue(rig.store.state(for: live.id).heldOrdinals.isEmpty, "precondition: the roll-in went through (nothing held)")
        XCTAssertTrue(rig.followTail.isPinned, "still following")
        XCTAssertLessThanOrEqual(rig.gapBelowViewport, 0.5, "the pane is at the true bottom")
        XCTAssertEqual(rig.snapshot().bottomOffsetPt, 0, accuracy: 0.5)
        XCTAssertTrue(rig.window.firstResponder === rig.textView, "the composer keeps focus")
        XCTAssertEqual(rig.textView.string, SafetyRig.typedText, "the composer text is untouched")
        XCTAssertEqual(rig.textView.selectedRange(), SafetyRig.typedSelection, "the composer selection is untouched")
        XCTAssertEqual(rig.inputBar.frame.height, bar, accuracy: 0.5, "the input bar did not change height")
        XCTAssertEqual(rig.composerScroll?.frame, scrollFrame, "the composer text scroll frame did not change")
    }
}
