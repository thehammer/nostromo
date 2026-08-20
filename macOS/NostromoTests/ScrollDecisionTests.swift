import XCTest

// `ScrollDecision` is compiled into this target directly (logic test — no
// host app, no `@testable import`), the same idiom as
// `PaneContentWireEqualityTests`.

/// Behavioural coverage for `ScrollDecision.decide` — the rule that keeps an
/// operator's viewport from being yanked by a re-emphasis on the same anchor
/// (W2 — curated-agent-views).
final class ScrollDecisionTests: XCTestCase {

    // MARK: 20. No anchor never moves the viewport

    func testNoAnchorLineIsAlwaysNoneRegardlessOfViewport() {
        XCTAssertEqual(ScrollDecision.decide(anchorLine: nil, visibleLines: nil), .none)
        XCTAssertEqual(ScrollDecision.decide(anchorLine: nil, visibleLines: 10...20), .none)
    }

    // MARK: 21. First paint (no layout yet) always honours the anchor

    func testNoVisibleLinesYetScrollsToTheAnchor() {
        XCTAssertEqual(ScrollDecision.decide(anchorLine: 5, visibleLines: nil), .scrollTo(line: 5))
    }

    // MARK: 22. An anchor already on screen must not move the viewport

    func testAnchorAlreadyWithinVisibleLinesIsNone() {
        let visible = 10...20
        XCTAssertEqual(ScrollDecision.decide(anchorLine: 10, visibleLines: visible), .none,
                       "the first visible line must count as already on screen")
        XCTAssertEqual(ScrollDecision.decide(anchorLine: 20, visibleLines: visible), .none,
                       "the last visible line must count as already on screen")
        XCTAssertEqual(ScrollDecision.decide(anchorLine: 15, visibleLines: visible), .none,
                       "a middle visible line must count as already on screen")
    }

    // MARK: 23. An anchor just outside the visible range scrolls to it exactly

    func testAnchorOneLineOutsideVisibleRangeScrollsToThatExactLine() {
        let visible = 10...20
        XCTAssertEqual(ScrollDecision.decide(anchorLine: 9, visibleLines: visible), .scrollTo(line: 9),
                       "one line above the visible range must scroll")
        XCTAssertEqual(ScrollDecision.decide(anchorLine: 21, visibleLines: visible), .scrollTo(line: 21),
                       "one line below the visible range must scroll")
    }
}
