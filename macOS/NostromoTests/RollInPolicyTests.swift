import XCTest
import AppKit

// FV3 (reader-protected roll-in): the policy, stated as a truth table.
//
// `RollInPolicy` is pure: what to hold, when to release, what to animate. Nothing here builds a
// view or reads a clock. The scroll scenarios that drive the real pane are in
// `FocusRollInScrollTests`.

final class RollInPolicyTests: XCTestCase {

    // MARK: Fixtures

    /// The viewport, in the document's coordinates.
    private let viewport = CGRect(x: 0, y: 0, width: 100, height: 100)

    private let fullyInside = CGRect(x: 10, y: 10, width: 50, height: 50)
    private let partlyInside = CGRect(x: 80, y: 80, width: 50, height: 50)
    /// Shares the viewport's bottom edge and nothing else: zero points of overlap.
    private let touchingBelow = CGRect(x: 0, y: 100, width: 100, height: 50)
    /// Shares the viewport's top edge from above.
    private let touchingAbove = CGRect(x: 0, y: -50, width: 100, height: 50)
    /// Shares the viewport's right edge.
    private let touchingSide = CGRect(x: 100, y: 0, width: 50, height: 100)
    private let disjointBelow = CGRect(x: 0, y: 300, width: 100, height: 50)
    private let disjointAbove = CGRect(x: 0, y: -300, width: 100, height: 50)

    private struct Placement {
        let name: String
        let rect: CGRect
        let visible: Bool
    }

    private var placements: [Placement] {
        [Placement(name: "fully visible", rect: fullyInside, visible: true),
         Placement(name: "partly visible", rect: partlyInside, visible: true),
         Placement(name: "touching the bottom edge", rect: touchingBelow, visible: false),
         Placement(name: "touching the top edge", rect: touchingAbove, visible: false),
         Placement(name: "touching the side edge", rect: touchingSide, visible: false),
         Placement(name: "disjoint below", rect: disjointBelow, visible: false),
         Placement(name: "disjoint above", rect: disjointAbove, visible: false)]
    }

    // MARK: isVisible

    func testAMessageIsVisibleOnlyWhenItOverlapsTheViewportByAPositiveWidthAndHeight() {
        for placement in placements {
            XCTAssertEqual(RollInPolicy.isVisible(placement.rect, in: viewport), placement.visible,
                           "a message \(placement.name)")
        }
    }

    func testAMessageThatOnlyTouchesTheViewportIsNotVisible() {
        XCTAssertFalse(RollInPolicy.isVisible(touchingBelow, in: viewport), "zero points of height overlap")
        XCTAssertFalse(RollInPolicy.isVisible(touchingAbove, in: viewport), "zero points of height overlap")
        XCTAssertFalse(RollInPolicy.isVisible(touchingSide, in: viewport), "zero points of width overlap")
    }

    func testAMessageOnePointInsideTheViewportIsVisible() {
        XCTAssertTrue(RollInPolicy.isVisible(CGRect(x: 0, y: 99, width: 100, height: 50), in: viewport))
        XCTAssertTrue(RollInPolicy.isVisible(CGRect(x: 99, y: 0, width: 50, height: 100), in: viewport))
        XCTAssertTrue(RollInPolicy.isVisible(CGRect(x: 0, y: -49, width: 100, height: 50), in: viewport))
    }

    func testAnEmptyMessageRectIsNotVisibleEvenInsideTheViewport() {
        XCTAssertFalse(RollInPolicy.isVisible(CGRect(x: 10, y: 10, width: 0, height: 0), in: viewport))
        XCTAssertFalse(RollInPolicy.isVisible(CGRect(x: 10, y: 10, width: 50, height: 0), in: viewport))
        XCTAssertFalse(RollInPolicy.isVisible(CGRect(x: 10, y: 10, width: 0, height: 50), in: viewport))
        XCTAssertFalse(RollInPolicy.isVisible(.zero, in: viewport))
    }

    func testAMessageThatCoversTheWholeViewportOrIsLargerThanItIsVisible() {
        XCTAssertTrue(RollInPolicy.isVisible(viewport, in: viewport))
        XCTAssertTrue(RollInPolicy.isVisible(CGRect(x: -50, y: -50, width: 400, height: 400), in: viewport))
    }

    // MARK: shouldHold

    func testAPaneThatIsNotFollowingHoldsAVisibleMessageAndRollsInOneThatIsNot() {
        for placement in placements {
            XCTAssertEqual(RollInPolicy.shouldHold(followingTail: false, messageRect: placement.rect,
                                                   visibleRect: viewport, selectionInMessage: false),
                           placement.visible, "not following, no selection, message \(placement.name)")
        }
    }

    func testAFollowingPaneWithNoSelectionNeverHoldsWhereverTheMessageIs() {
        for placement in placements {
            XCTAssertFalse(RollInPolicy.shouldHold(followingTail: true, messageRect: placement.rect,
                                                   visibleRect: viewport, selectionInMessage: false),
                           "following, no selection, message \(placement.name)")
        }
    }

    func testASelectionInsideTheMessageHoldsItWhetherOrNotThePaneFollowsAndWhereverItIs() {
        for following in [true, false] {
            for placement in placements {
                XCTAssertTrue(RollInPolicy.shouldHold(followingTail: following, messageRect: placement.rect,
                                                      visibleRect: viewport, selectionInMessage: true),
                              "following \(following), selection, message \(placement.name)")
            }
        }
    }

    func testTheFullHoldTruthTable() {
        for following in [true, false] {
            for placement in placements {
                for selection in [true, false] {
                    let expected = selection || (!following && placement.visible)
                    XCTAssertEqual(RollInPolicy.shouldHold(followingTail: following, messageRect: placement.rect,
                                                           visibleRect: viewport, selectionInMessage: selection),
                                   expected,
                                   "following \(following), selection \(selection), message \(placement.name)")
                }
            }
        }
    }

    func testAnEmptyMessageRectIsHeldOnlyBySelection() {
        XCTAssertFalse(RollInPolicy.shouldHold(followingTail: false, messageRect: .zero, visibleRect: viewport,
                                               selectionInMessage: false))
        XCTAssertTrue(RollInPolicy.shouldHold(followingTail: false, messageRect: .zero, visibleRect: viewport,
                                              selectionInMessage: true))
    }

    // MARK: shouldRelease

    func testAHeldMessageIsReleasedExactlyWhenTheHoldNoLongerApplies() {
        for following in [true, false] {
            for placement in placements {
                for selection in [true, false] {
                    let holds = RollInPolicy.shouldHold(followingTail: following, messageRect: placement.rect,
                                                        visibleRect: viewport, selectionInMessage: selection)
                    XCTAssertEqual(RollInPolicy.shouldRelease(followingTail: following, messageRect: placement.rect,
                                                              visibleRect: viewport, selectionInMessage: selection,
                                                              jumpedToLatest: false),
                                   !holds,
                                   "following \(following), selection \(selection), message \(placement.name)")
                }
            }
        }
    }

    func testJumpingToLatestReleasesEverythingEvenAMessageHeldBySelection() {
        for following in [true, false] {
            for placement in placements {
                for selection in [true, false] {
                    XCTAssertTrue(RollInPolicy.shouldRelease(followingTail: following, messageRect: placement.rect,
                                                             visibleRect: viewport, selectionInMessage: selection,
                                                             jumpedToLatest: true),
                                  "jump: following \(following), selection \(selection), message \(placement.name)")
                }
            }
        }
    }

    func testScrollingAVisibleMessageOutOfViewReleasesItInANonFollowingPane() {
        XCTAssertFalse(RollInPolicy.shouldRelease(followingTail: false, messageRect: partlyInside, visibleRect: viewport,
                                                  selectionInMessage: false, jumpedToLatest: false))
        XCTAssertTrue(RollInPolicy.shouldRelease(followingTail: false, messageRect: disjointBelow, visibleRect: viewport,
                                                 selectionInMessage: false, jumpedToLatest: false))
    }

    func testClearingTheSelectionReleasesAnOffScreenMessage() {
        XCTAssertFalse(RollInPolicy.shouldRelease(followingTail: false, messageRect: disjointAbove, visibleRect: viewport,
                                                  selectionInMessage: true, jumpedToLatest: false))
        XCTAssertTrue(RollInPolicy.shouldRelease(followingTail: false, messageRect: disjointAbove, visibleRect: viewport,
                                                 selectionInMessage: false, jumpedToLatest: false))
    }

    func testAPaneThatFollowsTheTailAgainReleasesAVisibleMessageUnlessItHoldsASelection() {
        XCTAssertTrue(RollInPolicy.shouldRelease(followingTail: true, messageRect: fullyInside, visibleRect: viewport,
                                                 selectionInMessage: false, jumpedToLatest: false))
        XCTAssertFalse(RollInPolicy.shouldRelease(followingTail: true, messageRect: fullyInside, visibleRect: viewport,
                                                  selectionInMessage: true, jumpedToLatest: false))
    }

    // MARK: animation

    func testOnlyAnOnScreenRollInInAFollowingPaneWithMotionOnCollapses() {
        for onScreen in [true, false] {
            for following in [true, false] {
                for reduceMotion in [true, false] {
                    let expected: RollInAnimation = onScreen && following && !reduceMotion
                        ? .collapse(duration: 0.15) : .none
                    XCTAssertEqual(RollInPolicy.animation(onScreen: onScreen, followingTail: following,
                                                          reduceMotion: reduceMotion),
                                   expected,
                                   "onScreen \(onScreen), following \(following), reduceMotion \(reduceMotion)")
                }
            }
        }
    }

    func testTheCollapseNeverTakesLongerThan150Milliseconds() {
        XCTAssertLessThanOrEqual(RollInPolicy.collapseDuration, 0.15)
        XCTAssertGreaterThan(RollInPolicy.collapseDuration, 0)
        guard case .collapse(let duration) = RollInPolicy.animation(onScreen: true, followingTail: true, reduceMotion: false) else {
            return XCTFail("an on-screen roll-in in a following pane animates")
        }
        XCTAssertLessThanOrEqual(duration, 0.15)
    }

    func testReduceMotionMakesEveryRollInInstant() {
        for onScreen in [true, false] {
            for following in [true, false] {
                XCTAssertEqual(RollInPolicy.animation(onScreen: onScreen, followingTail: following, reduceMotion: true),
                               .none, "onScreen \(onScreen), following \(following)")
            }
        }
    }

    // MARK: The bound

    func testATurnHoldsAtMostSixteenMessagesBack() {
        XCTAssertEqual(RollInPolicy.maxHeldPerTurn, 16)
    }
}
