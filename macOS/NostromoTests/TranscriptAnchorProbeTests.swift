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
}
