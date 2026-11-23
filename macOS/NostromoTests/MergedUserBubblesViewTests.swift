import XCTest
import AppKit

// The bubbles of a merged turn (`merged_turns_v1`): N user bubbles, each exactly what was typed, then
// a muted "sent together" caption; the height estimate; the cold-turn round trip; the turn view that
// shows them in the user slot. Merged turn rows ride the same `ChatTurn` the reconciler already keys by
// the joined `userInput`.

final class MergedUserBubblesViewTests: XCTestCase {

    private let parts = ["oh and backfill the rows", "use the new column name", "skip the tests"]

    func testItShowsOneBubbleEachWithTheExactTypedTextAndTheCaption() {
        let view = MergedUserBubblesView(parts: parts)
        XCTAssertEqual(view.shownParts, parts)
        XCTAssertEqual(view.captionText, "sent together")
    }

    func testVoiceOverReadsTheGroupWithTheCountAndEachBubbleItsText() {
        let view = MergedUserBubblesView(parts: parts)
        XCTAssertEqual(view.accessibilityLabel(), "Sent together, 3 messages")
        XCTAssertEqual(view.accessibilityRole(), .group)
        XCTAssertEqual(view.bubbles.map(\.shownText), parts, "each bubble carries its full text")
    }

    func testTheViewIsTallerThanOneBubbleAndGrowsWithEachPart() {
        func height(_ n: Int) -> CGFloat {
            let view = MergedUserBubblesView(parts: Array(parts.prefix(n)))
            view.frame = NSRect(x: 0, y: 0, width: 300, height: 10)
            view.layoutSubtreeIfNeeded()
            return view.fittingSize.height
        }
        XCTAssertGreaterThan(height(2), height(1))
        XCTAssertGreaterThan(height(3), height(2))
    }

    // MARK: the turn view

    func testATurnWithPartsFillsTheUserSlotWithTheMergedBubblesAndNotASingleBubble() {
        let turn = ChatTurn(userInput: parts.joined(separator: "\n\n"), timestamp: Date(), isComplete: true,
                            daemonId: "t0", userParts: parts)
        let view = ChatTurnView(turn: turn, contentAvailable: true, interaction: TurnInteractionState())
        XCTAssertEqual(view.mergedBubblesView?.shownParts, parts)
        XCTAssertFalse(view.hasUserBubble)
    }

    func testAnOrdinaryTurnStillGetsASingleBubble() {
        let turn = ChatTurn(userInput: "hello", timestamp: Date(), isComplete: true, daemonId: "t0")
        let view = ChatTurnView(turn: turn, contentAvailable: true, interaction: TurnInteractionState())
        XCTAssertNil(view.mergedBubblesView)
        XCTAssertEqual(view.userBubbleContent?.text, "hello")
    }

    // MARK: height estimate

    func testTheEstimatorCountsEveryBubbleAndTheCaption() {
        let one = ChatTurn(userInput: parts[0], timestamp: Date(), isComplete: true, daemonId: "t0")
        let merged = ChatTurn(userInput: parts.joined(separator: "\n\n"), timestamp: Date(), isComplete: true,
                              daemonId: "t1", userParts: parts)
        let h1 = TurnHeightEstimator.estimate(one, width: 600)
        let h3 = TurnHeightEstimator.estimate(merged, width: 600)
        XCTAssertGreaterThan(h3, h1 + 2 * TurnHeightEstimator.bubbleChrome,
                             "three bubbles and a caption are taller than one bubble")
    }

    // MARK: cold turns

    func testAColdTurnRehydratesAsTheSameBubbles() throws {
        let long = String(repeating: "x", count: TurnPayloadStore.prefixLength + 500)
        let all = [long, "short", long + "y"]
        let turn = ChatTurn(userInput: all.joined(separator: "\n\n"), timestamp: Date(), isComplete: true,
                            daemonId: "t0", userParts: all)

        let skeleton = TurnPayloadStore.skeleton(of: turn)
        XCTAssertEqual(skeleton.userParts.count, 3, "the skeleton still knows it is three bubbles")
        XCTAssertEqual(skeleton.userPartLengths, all.map(\.count), "heights keep the true sizes")
        XCTAssertLessThan(skeleton.userParts[0].count, long.count)

        let payload = try XCTUnwrap(TurnPayloadStore.encodePayload(turn))
        let back = try XCTUnwrap(TurnPayloadStore.decodePayload(payload, into: skeleton))
        XCTAssertEqual(back.userParts, all)
        XCTAssertEqual(back.userInput, turn.userInput)
    }

    func testIdentityIsTheJoinedTextSoALiveAndARebuiltTurnAgree() {
        let live = ChatTurn(userInput: parts.joined(separator: "\n\n"), timestamp: Date(), timestampRaw: "2026-11-22T12:00:01Z",
                            daemonId: "t0", userParts: parts)
        let rebuilt = ChatTurn(userInput: parts.joined(separator: "\n\n"), timestamp: Date(), timestampRaw: "2026-11-22T12:00:01Z",
                               daemonId: "t9", userParts: parts)
        XCTAssertEqual(live.identityKey, rebuilt.identityKey)
        XCTAssertTrue(TurnReconciler.matches(live, rebuilt))
    }
}
