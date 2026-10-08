import XCTest

// Behavioural spec for `selectDecisionTargets` / `decisionTier`: a decision
// popup lands on exactly ONE window, chosen by a three-rung ladder.
//
//   1. a visible window already showing the asking focus   (.askingFocus)
//   2. else a visible window showing some other focus      (.otherFocus)
//   3. else any window at all (nothing visible)            (.fallback)
//
// Inside a rung: the key window, then the lowest `order`, then input position.

final class DecisionTargetingTests: XCTestCase {

    private typealias Info = DecisionWindowInfo<Int>

    private func win(_ id: Int, visible: Bool = true, key: Bool = false,
                     order: Int = 0, focus: String? = nil) -> Info {
        DecisionWindowInfo(id: id, isVisible: visible, isKey: key, order: order, activeFocusTag: focus)
    }

    private func pick(_ windows: [Info], tag: String = "perri") -> [DecisionTarget<Int>] {
        selectDecisionTargets(windows: windows, requestTag: tag)
    }

    // MARK: - Ladder

    func testEmptyWindowListYieldsNoTarget() {
        XCTAssertTrue(pick([]).isEmpty)
    }

    func testVisibleWindowShowingTheAskingFocusIsTierOne() {
        let result = pick([win(1, focus: "perri")])
        XCTAssertEqual(result.map(\.id), [1])
        XCTAssertEqual(result.first?.tier, .askingFocus)
    }

    func testAskingFocusWindowBeatsTheKeyWindowShowingAnotherFocus() {
        let result = pick([
            win(1, key: true, order: 0, focus: "teri"),
            win(2, key: false, order: 5, focus: "perri"),
        ])
        XCTAssertEqual(result.map(\.id), [2])
        XCTAssertEqual(result.first?.tier, .askingFocus)
    }

    func testWhenNoVisibleWindowShowsTheAskingFocusAVisibleOtherFocusWindowIsTierTwo() {
        let result = pick([
            win(1, focus: "teri"),
            win(2, focus: "fred"),
        ])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.tier, .otherFocus)
    }

    func testVisibleWindowWithNoActiveFocusCountsAsOtherFocus() {
        let result = pick([win(1, focus: nil)])
        XCTAssertEqual(result.map(\.id), [1])
        XCTAssertEqual(result.first?.tier, .otherFocus)
    }

    func testInvisibleWindowShowingTheAskingFocusDoesNotBeatAVisibleWindowShowingAnotherFocus() {
        let result = pick([
            win(1, visible: false, key: true, order: 0, focus: "perri"),
            win(2, visible: true, key: false, order: 9, focus: "teri"),
        ])
        XCTAssertEqual(result.map(\.id), [2])
        XCTAssertEqual(result.first?.tier, .otherFocus)
    }

    func testWhenNothingIsVisibleTheFallbackIsTheKeyWindow() {
        let result = pick([
            win(1, visible: false, key: false, order: 0, focus: "perri"),
            win(2, visible: false, key: true, order: 7, focus: "teri"),
        ])
        XCTAssertEqual(result.map(\.id), [2])
        XCTAssertEqual(result.first?.tier, .fallback)
    }

    func testWhenNothingIsVisibleAndNoKeyWindowTheFallbackIsTheLowestOrder() {
        let result = pick([
            win(1, visible: false, order: 4),
            win(2, visible: false, order: 1),
            win(3, visible: false, order: 2),
        ])
        XCTAssertEqual(result.map(\.id), [2])
        XCTAssertEqual(result.first?.tier, .fallback)
    }

    // MARK: - Tie-breaks inside a tier

    func testWithinATierTheKeyWindowBeatsALowerOrderWindow() {
        let result = pick([
            win(1, key: false, order: 0, focus: "perri"),
            win(2, key: true, order: 5, focus: "perri"),
        ])
        XCTAssertEqual(result.map(\.id), [2])
    }

    func testWithinATierWithNoKeyWindowTheLowestOrderWins() {
        let result = pick([
            win(1, order: 3, focus: "perri"),
            win(2, order: 1, focus: "perri"),
            win(3, order: 2, focus: "perri"),
        ])
        XCTAssertEqual(result.map(\.id), [2])
    }

    func testWithinATierWithEqualOrderTheFirstInInputWins() {
        let result = pick([
            win(7, order: 2, focus: "perri"),
            win(3, order: 2, focus: "perri"),
            win(9, order: 2, focus: "perri"),
        ])
        XCTAssertEqual(result.map(\.id), [7])
    }

    func testTwoKeyWindowsFallBackToOrderThenInputPosition() {
        let result = pick([
            win(1, key: true, order: 4, focus: "teri"),
            win(2, key: true, order: 1, focus: "teri"),
        ])
        XCTAssertEqual(result.map(\.id), [2])
    }

    func testOtherFocusTierAlsoPrefersKeyThenOrder() {
        let keyWins = pick([
            win(1, key: false, order: 0, focus: "teri"),
            win(2, key: true, order: 3, focus: "fred"),
        ])
        XCTAssertEqual(keyWins.map(\.id), [2])

        let orderWins = pick([
            win(1, order: 5, focus: "teri"),
            win(2, order: 2, focus: "fred"),
        ])
        XCTAssertEqual(orderWins.map(\.id), [2])
    }

    func testNeverMoreThanOneTargetEvenWithManyMatchingWindows() {
        let many = (0..<12).map { win($0, key: $0 == 5, order: $0, focus: "perri") }
        XCTAssertEqual(pick(many).count, 1)

        let manyInvisible = (0..<12).map { win($0, visible: false, order: $0) }
        XCTAssertEqual(pick(manyInvisible).count, 1)
    }

    func testRequestTagIsMatchedExactly() {
        let result = pick([win(1, focus: "perri-abc12345")], tag: "perri")
        XCTAssertEqual(result.first?.tier, .otherFocus)
    }

    // MARK: - decisionTier(of:requestTag:)

    func testTierOfAVisibleWindowShowingTheTagIsAskingFocus() {
        XCTAssertEqual(decisionTier(of: win(1, focus: "perri"), requestTag: "perri"), .askingFocus)
    }

    func testTierOfAVisibleWindowShowingAnotherFocusOrNoneIsOtherFocus() {
        XCTAssertEqual(decisionTier(of: win(1, focus: "teri"), requestTag: "perri"), .otherFocus)
        XCTAssertEqual(decisionTier(of: win(1, focus: nil), requestTag: "perri"), .otherFocus)
    }

    func testTierOfAnInvisibleWindowIsFallbackWhateverItShows() {
        XCTAssertEqual(decisionTier(of: win(1, visible: false, focus: "perri"), requestTag: "perri"), .fallback)
        XCTAssertEqual(decisionTier(of: win(1, visible: false, focus: "teri"), requestTag: "perri"), .fallback)
        XCTAssertEqual(decisionTier(of: win(1, visible: false, key: true, focus: nil), requestTag: "perri"), .fallback)
    }

    func testKeyStatusDoesNotChangeATiersClassification() {
        XCTAssertEqual(decisionTier(of: win(1, key: true, focus: "teri"), requestTag: "perri"), .otherFocus)
        XCTAssertEqual(decisionTier(of: win(1, key: true, focus: "perri"), requestTag: "perri"), .askingFocus)
    }

    func testTiersAreOrderedAskingFocusBeforeOtherFocusBeforeFallback() {
        XCTAssertLessThan(DecisionTargetTier.askingFocus, .otherFocus)
        XCTAssertLessThan(DecisionTargetTier.otherFocus, .fallback)
        XCTAssertLessThan(DecisionTargetTier.askingFocus, .fallback)
        XCTAssertFalse(DecisionTargetTier.fallback < .askingFocus)
    }
}
