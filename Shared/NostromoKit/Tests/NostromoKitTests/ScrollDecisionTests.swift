import XCTest
@testable import NostromoKit

// Ported verbatim from `macOS/NostromoTests/ScrollDecisionTests.swift`
// (ios-curated-view-parity W7).

/// Behavioural coverage for `ScrollDecision.decide` — the rule that keeps an
/// operator's viewport from being yanked by a re-emphasis on the same anchor
/// (W2 — curated-agent-views; ported to NostromoKit in ios-curated-view-parity
/// W7).
final class ScrollDecisionTests: XCTestCase {

    // MARK: 20. No anchor never moves the viewport

    func testNoAnchorLineIsAlwaysNoneRegardlessOfViewport() {
        XCTAssertEqual(ScrollDecision.decide(anchor: nil, visibleRange: nil), .none)
        XCTAssertEqual(ScrollDecision.decide(anchor: nil, visibleRange: 10...20), .none)
    }

    // MARK: 21. First paint (no layout yet) always honours the anchor

    func testNoVisibleLinesYetScrollsToTheAnchor() {
        XCTAssertEqual(ScrollDecision.decide(anchor: 5, visibleRange: nil), .scrollTo(target: 5))
    }

    // MARK: 22. An anchor already on screen must not move the viewport

    func testAnchorAlreadyWithinVisibleLinesIsNone() {
        let visible = 10...20
        XCTAssertEqual(ScrollDecision.decide(anchor: 10, visibleRange: visible), .none,
                       "the first visible line must count as already on screen")
        XCTAssertEqual(ScrollDecision.decide(anchor: 20, visibleRange: visible), .none,
                       "the last visible line must count as already on screen")
        XCTAssertEqual(ScrollDecision.decide(anchor: 15, visibleRange: visible), .none,
                       "a middle visible line must count as already on screen")
    }

    // MARK: 23. An anchor just outside the visible range scrolls to it exactly

    func testAnchorOneLineOutsideVisibleRangeScrollsToThatExactLine() {
        let visible = 10...20
        XCTAssertEqual(ScrollDecision.decide(anchor: 9, visibleRange: visible), .scrollTo(target: 9),
                       "one line above the visible range must scroll")
        XCTAssertEqual(ScrollDecision.decide(anchor: 21, visibleRange: visible), .scrollTo(target: 21),
                       "one line below the visible range must scroll")
    }
}
