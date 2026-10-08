import XCTest
import CoreGraphics

// FollowTailPolicy is compiled into this target directly (logic test).

/// Behavioural coverage for the rule that decides whether a transcript pane is
/// following its newest message. The bug this guards: a non-user bounds change
/// (resize, split collapse/restore, input-bar growth, window re-show) landing
/// after a turn was appended but before the pane scrolled to it used to clear
/// "following" for good. Only the operator scrolling away may un-pin.
final class FollowTailPolicyTests: XCTestCase {

    /// Convenience: one bounds-change event with the defaults of a plain
    /// "nothing special happened" tick.
    private func pinned(after current: Bool,
                        originDeltaY: CGFloat = 0,
                        sizeChanged: Bool = false,
                        isMaterializing: Bool = false,
                        documentHeight: CGFloat,
                        visibleMaxY: CGFloat) -> Bool {
        FollowTailPolicy.pinnedAfterBoundsChange(
            current: current,
            originDeltaY: originDeltaY,
            sizeChanged: sizeChanged,
            isMaterializing: isMaterializing,
            documentHeight: documentHeight,
            visibleMaxY: visibleMaxY)
    }

    // MARK: - A pinned pane keeps following while content grows under it

    func testPinnedPaneStaysPinnedWhenAppendedTurnsGrowTheDocumentAndThePaneIsResized() {
        // Document grew to 5000 (turns appended) but the viewport still ends at 4700.
        XCTAssertTrue(pinned(after: true, originDeltaY: 0, sizeChanged: true,
                             documentHeight: 5000, visibleMaxY: 4700))
    }

    func testPinnedPaneStaysPinnedOnAStrayBoundsChangeWithNoMovement() {
        XCTAssertTrue(pinned(after: true, originDeltaY: 0, sizeChanged: false,
                             documentHeight: 5000, visibleMaxY: 4700))
    }

    func testPinnedPaneStaysPinnedWhenOurOwnScrollRacesTheGrowingDocument() {
        // Origin moved down (our own scroll-to-bottom), but the document is
        // already taller than where that scroll landed.
        XCTAssertTrue(pinned(after: true, originDeltaY: 120, sizeChanged: false,
                             documentHeight: 5000, visibleMaxY: 4700))
    }

    func testBoundsChangeDuringMaterializationNeverChangesPinnedState() {
        // Pinned and far from the bottom: still pinned.
        XCTAssertTrue(pinned(after: true, originDeltaY: -300, isMaterializing: true,
                             documentHeight: 5000, visibleMaxY: 1000))
        // Unpinned but sitting at the bottom: still unpinned.
        XCTAssertFalse(pinned(after: false, originDeltaY: 200, isMaterializing: true,
                              documentHeight: 5000, visibleMaxY: 5000))
    }

    func testResizeNeverChangesPinnedStateEvenFarFromOrNearTheBottom() {
        XCTAssertTrue(pinned(after: true, originDeltaY: -50, sizeChanged: true,
                             documentHeight: 5000, visibleMaxY: 1000))
        XCTAssertFalse(pinned(after: false, originDeltaY: 50, sizeChanged: true,
                              documentHeight: 5000, visibleMaxY: 5000))
    }

    // MARK: - The operator scrolling up un-pins

    func testUserScrollingUpAwayFromTheBottomUnpins() {
        XCTAssertFalse(pinned(after: true, originDeltaY: -80,
                              documentHeight: 5000, visibleMaxY: 4800))
    }

    func testUserScrollingUpFarFromTheBottomStaysUnpinned() {
        XCTAssertFalse(pinned(after: false, originDeltaY: -80,
                              documentHeight: 5000, visibleMaxY: 2000))
    }

    // MARK: - Returning to the bottom re-pins

    func testUserScrollingBackWithinThresholdOfTheBottomRepins() {
        XCTAssertTrue(pinned(after: false, originDeltaY: 200,
                             documentHeight: 5000, visibleMaxY: 4980))
    }

    func testPinThresholdBoundaryIsExclusiveAtForty() {
        XCTAssertEqual(FollowTailPolicy.pinThreshold, 40)
        XCTAssertTrue(pinned(after: false, originDeltaY: 10,
                             documentHeight: 5000, visibleMaxY: 5000 - 39.9),
                      "39.9 pt from the bottom counts as at the bottom")
        XCTAssertFalse(pinned(after: false, originDeltaY: 10,
                              documentHeight: 5000, visibleMaxY: 5000 - 40),
                       "exactly 40 pt from the bottom does not")
    }

    func testIsNearBottomMatchesTheThreshold() {
        XCTAssertTrue(FollowTailPolicy.isNearBottom(documentHeight: 1000, visibleMaxY: 1000))
        XCTAssertTrue(FollowTailPolicy.isNearBottom(documentHeight: 1000, visibleMaxY: 960.1))
        XCTAssertFalse(FollowTailPolicy.isNearBottom(documentHeight: 1000, visibleMaxY: 960))
    }

    // MARK: - An unpinned viewport must not re-pin by itself

    func testUnpinnedPaneStaysUnpinnedWhenDocumentGrowsAndViewportDidNotMove() {
        XCTAssertFalse(pinned(after: false, originDeltaY: 0,
                              documentHeight: 5000, visibleMaxY: 2000))
    }

    func testUnpinnedPaneStaysUnpinnedWhenOriginMovesDownButStaysFarFromTheBottom() {
        XCTAssertFalse(pinned(after: false, originDeltaY: 60,
                              documentHeight: 5000, visibleMaxY: 2000))
    }

    // MARK: - A hidden pane keeps following through content arriving and resizes

    func testPaneHiddenWhileTurnsStreamInStillFollowsOnceItComesBack() {
        var isPinned = true
        var documentHeight: CGFloat = 4000
        let visibleMaxY: CGFloat = 4000   // viewport never gets to scroll while hidden

        // Turns arrive; between each, the pane is collapsed to zero width and restored.
        for appended in [300, 450, 900, 1200] as [CGFloat] {
            documentHeight += appended
            // collapse
            isPinned = pinned(after: isPinned, originDeltaY: 0, sizeChanged: true,
                              documentHeight: documentHeight, visibleMaxY: visibleMaxY)
            // restore
            isPinned = pinned(after: isPinned, originDeltaY: 0, sizeChanged: true,
                              documentHeight: documentHeight, visibleMaxY: visibleMaxY)
            // a stray tick for good measure
            isPinned = pinned(after: isPinned, originDeltaY: 0, sizeChanged: false,
                              documentHeight: documentHeight, visibleMaxY: visibleMaxY)
        }

        XCTAssertTrue(isPinned, "a pane the operator never scrolled must still be following")
        XCTAssertTrue(FollowTailPolicy.shouldCatchUp(isPinned: isPinned, contentWidth: 640, passWasSkipped: true))
    }

    // MARK: - Catch-up when a pane becomes usable again

    func testCatchUpIsScheduledOnlyForAPinnedUsablePaneThatSkippedAPass() {
        XCTAssertTrue(FollowTailPolicy.shouldCatchUp(isPinned: true, contentWidth: 640, passWasSkipped: true))
        XCTAssertFalse(FollowTailPolicy.shouldCatchUp(isPinned: false, contentWidth: 640, passWasSkipped: true),
                       "an operator who scrolled away is not yanked back")
        XCTAssertFalse(FollowTailPolicy.shouldCatchUp(isPinned: true, contentWidth: 1, passWasSkipped: true),
                       "a collapsed pane cannot be laid out")
        XCTAssertFalse(FollowTailPolicy.shouldCatchUp(isPinned: true, contentWidth: 0, passWasSkipped: true))
        XCTAssertFalse(FollowTailPolicy.shouldCatchUp(isPinned: true, contentWidth: 640, passWasSkipped: false),
                       "nothing was missed")
    }

    // MARK: - Jump to latest affordance

    func testJumpToLatestShowsExactlyWhenNotFollowing() {
        XCTAssertFalse(FollowTailPolicy.showsJumpToLatest(isPinned: true))
        XCTAssertTrue(FollowTailPolicy.showsJumpToLatest(isPinned: false))
    }
}
