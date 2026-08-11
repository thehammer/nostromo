import XCTest
import CoreGraphics
// ChatTurn, TurnBlock, TurnHeightEstimator and TurnListVirtualizer are compiled
// into this target directly (logic test — no host app). No module imports needed.

// MARK: - TurnListVirtualizerTests

/// Behavioural tests for `TurnListVirtualizer`.
///
/// The contract under test is transcript *geometry*, stated entirely in terms of
/// the virtualizer's public answers: how tall the document is, where a turn sits,
/// which turns intersect the viewport, and — the one that the operator actually
/// feels — where the viewport has to move so the thing they were reading does not
/// jump while heights are corrected underneath it.
///
/// Nothing here reads the Fenwick tree, the heights array, or the measured-height
/// cache. The single exception is `treeOperations`, which the implementation
/// exposes precisely so the O(log n) claim can be asserted by counting nodes
/// instead of by timing a loop; a wall-clock assertion would be flaky on a shared
/// CI machine and would not actually distinguish a log-time tree from a fast
/// linear scan over five thousand elements.
///
/// Two facts about the type shape these tests:
///
///  - Heights are two-tier. Every turn starts as an arithmetic estimate and is
///    corrected to a real measurement when it materializes. The document height
///    therefore changes *while the operator is reading*, which is the entire
///    reason `Anchor` exists.
///  - Turns are addressed by `contentKey`, not by index. A splice renumbers
///    indices, so an anchor that followed its index would drag the reading
///    position by however many turns were inserted.
final class TurnListVirtualizerTests: XCTestCase {

    // MARK: - Fixtures

    private static let baseDate = Date(timeIntervalSince1970: 1_770_000_000)

    /// The pane width used by every test that does not vary width itself.
    private static let paneWidth: CGFloat = 800

    /// A turn with a unique content key but a character count identical to every
    /// other turn built this way — so a list of them has uniform, exactly
    /// predictable geometry while still being individually addressable.
    ///
    /// The index is zero-padded and the user text padded to a fixed length
    /// precisely so that "unique identity" does not accidentally mean "different
    /// height".
    private func uniformTurn(_ index: Int, bodyCharacters: Int = 1_200) -> ChatTurn {
        let label = String(format: "turn %06d", index)   // constant width
        let user  = label + String(repeating: "x", count: 200 - label.count)
        return ChatTurn(userInput:    user,
                        timestamp:    Self.baseDate.addingTimeInterval(Double(index)),
                        timestampRaw: String(format: "2026-08-11T12:00:00.%06dZ", index),
                        blocks:       [.text(String(repeating: "y", count: bodyCharacters))],
                        isComplete:   true,
                        daemonId:     "t\(index)",
                        epoch:        0)
    }

    private func uniformTurns(_ count: Int, bodyCharacters: Int = 1_200) -> [ChatTurn] {
        (0 ..< count).map { uniformTurn($0, bodyCharacters: bodyCharacters) }
    }

    /// A deliberately short turn, so that a tall viewport covers more than
    /// `maxMaterialized` of them and the clamp becomes the binding constraint.
    private func shortTurn(_ index: Int) -> ChatTurn {
        ChatTurn(userInput:    String(format: "s%06d", index),
                 timestamp:    Self.baseDate.addingTimeInterval(Double(index)),
                 timestampRaw: String(format: "2026-08-11T13:00:00.%06dZ", index),
                 blocks:       [],
                 isComplete:   true,
                 daemonId:     "t\(index)",
                 epoch:        0)
    }

    private func viewport(top: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: 0, y: top, width: Self.paneWidth, height: height)
    }

    private func makeVirtualizer(_ turns: [ChatTurn],
                                 width: CGFloat = TurnListVirtualizerTests.paneWidth)
        -> TurnListVirtualizer {
        let v = TurnListVirtualizer()
        v.reset(turns: turns, width: width)
        return v
    }

    // MARK: - Assertion helpers

    /// Where the anchored turn's top edge sits relative to the top of the
    /// viewport. This is the number the operator perceives as "my place in the
    /// transcript", and the only thing anchoring promises to preserve.
    private func anchorScreenPosition(_ v: TurnListVirtualizer,
                                      anchor: TurnListVirtualizer.Anchor,
                                      viewportTop: CGFloat) -> CGFloat {
        v.offset(of: anchor.index) - viewportTop
    }

    private func assertInBounds(_ range: Range<Int>, count: Int,
                                _ message: String = "",
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertGreaterThanOrEqual(range.lowerBound, 0,
                                    "\(message) window starts before the list", file: file, line: line)
        XCTAssertLessThanOrEqual(range.upperBound, count,
                                 "\(message) window ends past the list", file: file, line: line)
        XCTAssertLessThanOrEqual(range.lowerBound, range.upperBound,
                                 "\(message) window is inverted", file: file, line: line)
        XCTAssertLessThanOrEqual(range.count, TurnListVirtualizer.maxMaterialized,
                                 "\(message) window exceeds the materialization cap",
                                 file: file, line: line)
    }

    /// Ops consumed by `body`, measured through the instrumented node counter.
    private func treeOps(_ v: TurnListVirtualizer, _ body: () -> Void) -> Int {
        let before = v.treeOperations
        body()
        return v.treeOperations - before
    }

    private func ceilLog2(_ n: Int) -> Int {
        var bits = 0
        var value = 1
        while value < n { value <<= 1; bits += 1 }
        return max(bits, 1)
    }

    // MARK: - 1. Window size is a function of the viewport, not of the list

    func testWindowSizeIsIndependentOfListLength() {
        let short = makeVirtualizer(uniformTurns(100))
        let long  = makeVirtualizer(uniformTurns(5_000))

        // Mid-list, far from either end, so no clamping-at-the-edges effect can
        // explain a match.
        let box = viewport(top: 3_000, height: 600)
        let shortWindow = short.visibleWindow(viewport: box)
        let longWindow  = long.visibleWindow(viewport: box)

        XCTAssertEqual(shortWindow.count, longWindow.count,
                       "a 50x longer transcript must not materialize more views")
        XCTAssertEqual(shortWindow, longWindow,
                       "identical geometry and identical viewport must select identical turns")
        assertInBounds(shortWindow, count: 100, "100 turns:")
        assertInBounds(longWindow, count: 5_000, "5000 turns:")
    }

    func testWindowNeverExceedsMaxMaterializedEvenWhenTheViewportCoversMore() {
        let turns = (0 ..< 2_000).map { shortTurn($0) }
        let v = makeVirtualizer(turns)

        // Short turns plus a tall viewport plus a screen of overscan either side:
        // the geometric window is far more than the cap allows.
        let box = viewport(top: 5_000, height: 1_600)
        let uncappedTurns = Int((box.height * (1 + 2 * TurnListVirtualizer.overscanScreens))
                                / v.height(at: 0))
        XCTAssertGreaterThan(uncappedTurns, TurnListVirtualizer.maxMaterialized,
                             "fixture must actually exercise the cap")

        let window = v.visibleWindow(viewport: box)
        XCTAssertEqual(window.count, TurnListVirtualizer.maxMaterialized)
        assertInBounds(window, count: turns.count)
    }

    func testWhenTheWindowIsCappedItKeepsTheNewestTurns() {
        let turns = (0 ..< 2_000).map { shortTurn($0) }
        let v = makeVirtualizer(turns)
        let box = viewport(top: 5_000, height: 1_600)

        let capped   = v.visibleWindow(viewport: box)
        let bottomAt = v.index(atY: box.maxY)

        XCTAssertEqual(capped.count, TurnListVirtualizer.maxMaterialized)
        XCTAssertGreaterThan(capped.upperBound, bottomAt,
                             "the turn under the bottom edge of the viewport must survive the cap")
        XCTAssertTrue(capped.contains(bottomAt),
                      "a reader following a stream is looking at the newest end")
    }

    // MARK: - 2. Anchor stability under height corrections above the anchor

    func testAnchorHoldsItsScreenPositionWhenHeightsAboveItAreCorrected() {
        let v = makeVirtualizer(uniformTurns(400))

        let viewportTop: CGFloat = 12_345
        guard let anchor = v.captureAnchor(viewportTop: viewportTop) else {
            return XCTFail("a non-empty transcript must yield an anchor")
        }
        XCTAssertGreaterThan(anchor.index, 0, "fixture must anchor mid-list")
        let before = anchorScreenPosition(v, anchor: anchor, viewportTop: viewportTop)

        // Every turn above the anchor turns out to be much taller than estimated.
        for i in 0 ..< anchor.index {
            v.recordMeasured(v.height(at: i) + CGFloat(37 + i % 11), at: i)
        }

        let restored = v.restoredTop(for: anchor)
        let after = anchorScreenPosition(v, anchor: anchor, viewportTop: restored)

        XCTAssertEqual(after, before, accuracy: 1.0,
                       "the anchored turn must stay put on screen while the geometry above it changes")
        XCTAssertGreaterThan(restored, viewportTop,
                             "the scroll offset itself must move — otherwise nothing was corrected")
    }

    func testAnchorHoldsItsScreenPositionWhenHeightsAboveItShrink() {
        let v = makeVirtualizer(uniformTurns(400))
        let viewportTop: CGFloat = 12_345
        guard let anchor = v.captureAnchor(viewportTop: viewportTop) else {
            return XCTFail("a non-empty transcript must yield an anchor")
        }
        let before = anchorScreenPosition(v, anchor: anchor, viewportTop: viewportTop)

        for i in 0 ..< anchor.index {
            v.recordMeasured(max(1, v.height(at: i) - 40), at: i)
        }

        let restored = v.restoredTop(for: anchor)
        XCTAssertEqual(anchorScreenPosition(v, anchor: anchor, viewportTop: restored),
                       before, accuracy: 1.0)
        XCTAssertLessThan(restored, viewportTop,
                          "shrinking the content above must pull the scroll offset up")
    }

    func testAnchorSurvivesTurnsBeingInsertedAboveIt() {
        // The reason the anchor is keyed by content and not by index: a splice
        // renumbers everything after it.
        var turns = uniformTurns(200)
        let v = makeVirtualizer(turns)

        let viewportTop: CGFloat = 20_000
        guard let anchor = v.captureAnchor(viewportTop: viewportTop) else {
            return XCTFail("a non-empty transcript must yield an anchor")
        }
        let anchorKey = anchor.key
        let before = anchorScreenPosition(v, anchor: anchor, viewportTop: viewportTop)

        // Three turns arrive at index 10, shifting the anchor's index by three.
        let inserted = (900 ..< 903).map { uniformTurn($0) }
        turns.insert(contentsOf: inserted, at: 10)
        v.splice(turns: turns, from: 10)

        guard let newIndex = turns.firstIndex(where: { $0.contentKey == anchorKey }) else {
            return XCTFail("the anchored turn must still be in the transcript")
        }
        XCTAssertEqual(newIndex, anchor.index + 3, "fixture must actually renumber the anchor")

        let restored = v.restoredTop(for: anchor)
        XCTAssertEqual(v.offset(of: newIndex) - restored, before, accuracy: 1.0,
                       "re-resolving by content key must put the same turn back under the same pixel")
    }

    // MARK: - 3. Estimate → exact correction above the viewport

    func testExactCorrectionAboveTheViewportMovesTheDocumentButNotTheReader() {
        let v = makeVirtualizer(uniformTurns(300))

        let viewportTop: CGFloat = 20_000
        guard let anchor = v.captureAnchor(viewportTop: viewportTop) else {
            return XCTFail("a non-empty transcript must yield an anchor")
        }
        let target = anchor.index / 2
        XCTAssertFalse(v.isHeightExact(at: target), "the turn must start out estimated")

        let before      = anchorScreenPosition(v, anchor: anchor, viewportTop: viewportTop)
        let documentWas = v.documentHeight
        let estimated   = v.height(at: target)

        let delta = v.recordMeasured(estimated + 250, at: target)

        XCTAssertEqual(delta, 250, accuracy: 0.001,
                       "the correction must report exactly what the caller has to absorb")
        XCTAssertTrue(v.isHeightExact(at: target))
        XCTAssertEqual(v.documentHeight, documentWas + 250, accuracy: 0.001,
                       "an exact height above the viewport must change the document")
        XCTAssertEqual(anchorScreenPosition(v, anchor: anchor,
                                            viewportTop: v.restoredTop(for: anchor)),
                       before, accuracy: 1.0,
                       "...and must not move what the operator is reading")
    }

    func testCorrectionsBelowTheViewportDoNotMoveTheScrollOffsetAtAll() {
        let v = makeVirtualizer(uniformTurns(300))
        let viewportTop: CGFloat = 20_000
        guard let anchor = v.captureAnchor(viewportTop: viewportTop) else {
            return XCTFail("a non-empty transcript must yield an anchor")
        }
        let documentWas = v.documentHeight

        for i in (anchor.index + 5) ..< 300 {
            v.recordMeasured(v.height(at: i) + 90, at: i)
        }

        XCTAssertGreaterThan(v.documentHeight, documentWas)
        XCTAssertEqual(v.restoredTop(for: anchor), viewportTop, accuracy: 0.001,
                       "nothing above the anchor changed, so the scroll offset must not move")
    }

    // MARK: - 4. Complexity: logarithmic, asserted by node count

    /// The claim in the header of `TurnListVirtualizer` is that offset queries,
    /// height corrections and hit-testing are all O(log n). These assertions
    /// count Fenwick nodes touched rather than measuring elapsed time: a linear
    /// implementation would be *fast* at n = 5,000 on a modern machine and would
    /// sail through any wall-clock threshold loose enough not to be flaky.
    private func maxOffsetOps(_ n: Int) -> Int {
        let v = makeVirtualizer(uniformTurns(n))
        var worst = 0
        for i in sampleIndices(n) {
            worst = max(worst, treeOps(v) { _ = v.offset(of: i) })
        }
        return worst
    }

    private func maxRecordMeasuredOps(_ n: Int) -> Int {
        let v = makeVirtualizer(uniformTurns(n))
        var worst = 0
        for (bump, i) in sampleIndices(n).enumerated() {
            // A non-zero delta, so the update path is never short-circuited.
            let height = v.height(at: i) + CGFloat(bump + 1)
            worst = max(worst, treeOps(v) { _ = v.recordMeasured(height, at: i) })
        }
        return worst
    }

    private func maxIndexAtYOps(_ n: Int) -> Int {
        let v = makeVirtualizer(uniformTurns(n))
        let document = v.documentHeight
        var worst = 0
        for i in sampleIndices(n) {
            let y = document * CGFloat(i) / CGFloat(n)
            worst = max(worst, treeOps(v) { _ = v.index(atY: y) })
        }
        return worst
    }

    /// A dense spread, so the worst case of each operation is actually hit.
    private func sampleIndices(_ n: Int) -> [Int] {
        let step = max(1, n / 250)
        var out = Array(stride(from: 0, to: n, by: step))
        out.append(contentsOf: [0, 1, n / 2, n - 2, n - 1].filter { $0 >= 0 && $0 < n })
        return out
    }

    func testOffsetQueryCostGrowsLogarithmicallyNotLinearlyInListLength() {
        let small = maxOffsetOps(100)
        let large = maxOffsetOps(5_000)

        XCTAssertGreaterThan(small, 0, "the counter must actually be observing work")
        XCTAssertLessThanOrEqual(large, 2 * ceilLog2(5_000),
                                 "offset(of:) must stay within a constant factor of log2(n)")
        // Linear would make this ratio ~50. Five is an order of magnitude of
        // headroom and still nowhere near linear.
        XCTAssertLessThanOrEqual(large, small * 5,
                                 "a 50x longer list must not cost proportionally more per query")
    }

    func testHeightCorrectionCostGrowsLogarithmicallyNotLinearlyInListLength() {
        let small = maxRecordMeasuredOps(100)
        let large = maxRecordMeasuredOps(5_000)

        XCTAssertGreaterThan(small, 0)
        XCTAssertLessThanOrEqual(large, 2 * ceilLog2(5_000),
                                 "recordMeasured must stay within a constant factor of log2(n)")
        XCTAssertLessThanOrEqual(large, small * 5,
                                 "a materialization pass corrects up to 60 heights per scroll tick")
    }

    func testHitTestCostGrowsLogarithmicallyNotLinearlyInListLength() {
        let small = maxIndexAtYOps(100)
        let large = maxIndexAtYOps(5_000)

        XCTAssertGreaterThan(small, 0)
        XCTAssertLessThanOrEqual(large, 2 * ceilLog2(5_000),
                                 "index(atY:) is asked on every scroll event and must be a descent")
        XCTAssertLessThanOrEqual(large, small * 5,
                                 "hit-testing must not degrade into a scan")
    }

    func testAFullMaterializationPassOverAHugeListStaysWellUnderLinearCost() {
        // The concrete scenario from the header comment: 60 height corrections on
        // a 5,000-turn transcript, on the main thread, per scroll tick. A prefix-
        // sum array would cost ~150,000 writes.
        let v = makeVirtualizer(uniformTurns(5_000))
        let window = v.visibleWindow(viewport: viewport(top: 500_000, height: 900))
        XCTAssertFalse(window.isEmpty)

        let ops = treeOps(v) {
            for (bump, i) in window.enumerated() {
                _ = v.recordMeasured(v.height(at: i) + CGFloat(bump + 1), at: i)
            }
        }
        XCTAssertLessThanOrEqual(ops, window.count * 2 * ceilLog2(5_000))
        XCTAssertLessThan(ops, 5_000,
                          "a whole materialization pass must cost less than one linear sweep")
    }

    // MARK: - 5. Width invalidation

    func testInvalidateWidthReEstimatesEveryTurnAndPreservesTheAnchor() {
        let turns = uniformTurns(300)
        let v = makeVirtualizer(turns)

        let viewportTop: CGFloat = 20_000
        guard let anchor = v.captureAnchor(viewportTop: viewportTop) else {
            return XCTFail("a non-empty transcript must yield an anchor")
        }
        let before = anchorScreenPosition(v, anchor: anchor, viewportTop: viewportTop)
        let wideHeights = (0 ..< 300).map { v.height(at: $0) }

        v.invalidateWidth(400, turns: turns)

        for i in 0 ..< 300 {
            XCTAssertGreaterThan(v.height(at: i), wideHeights[i],
                                 "turn \(i) must re-wrap taller in a narrower pane")
        }
        XCTAssertEqual(anchorScreenPosition(v, anchor: anchor,
                                            viewportTop: v.restoredTop(for: anchor)),
                       before, accuracy: 1.0,
                       "a resize must not move the operator's reading position")
    }

    func testInvalidateWidthDiscardsHeightsMeasuredAtTheOldWidth() {
        let turns = uniformTurns(50)
        let v = makeVirtualizer(turns)
        v.recordMeasured(999, at: 10)
        XCTAssertTrue(v.isHeightExact(at: 10))

        v.invalidateWidth(400, turns: turns)

        XCTAssertFalse(v.isHeightExact(at: 10),
                       "a height measured at 800 pt says nothing about the same turn at 400 pt")
        XCTAssertNotEqual(v.height(at: 10), 999)
    }

    func testReturningToAPreviouslyMeasuredWidthRecoversTheMeasuredHeight() {
        let turns = uniformTurns(50)
        let v = makeVirtualizer(turns)
        v.recordMeasured(999, at: 10)

        v.invalidateWidth(400, turns: turns)
        v.invalidateWidth(Self.paneWidth, turns: turns)

        XCTAssertEqual(v.height(at: 10), 999, accuracy: 0.001,
                       "measuring the same turn at the same width twice is wasted layout")
        XCTAssertTrue(v.isHeightExact(at: 10))
    }

    // MARK: - 6. Scroll round trip

    func testScrollingToTheBottomAndBackReturnsTheSameWindowAndAnchor() {
        let v = makeVirtualizer(uniformTurns(1_000))
        let box = viewport(top: 0, height: 700)

        let topWindow = v.visibleWindow(viewport: box)
        let topAnchor = v.captureAnchor(viewportTop: box.minY)

        let bottomTop = v.documentHeight - box.height
        _ = v.visibleWindow(viewport: viewport(top: bottomTop, height: box.height))
        _ = v.captureAnchor(viewportTop: bottomTop)

        XCTAssertEqual(v.visibleWindow(viewport: box), topWindow)
        XCTAssertEqual(v.captureAnchor(viewportTop: box.minY), topAnchor)
    }

    func testScrollingToTheBottomMeasuringThereAndComingBackRestoresTheTopExactly() {
        let v = makeVirtualizer(uniformTurns(1_000))
        let box = viewport(top: 0, height: 700)

        let topWindow = v.visibleWindow(viewport: box)
        guard let topAnchor = v.captureAnchor(viewportTop: box.minY) else {
            return XCTFail("a non-empty transcript must yield an anchor")
        }

        // Materialize at the bottom, correcting every height down there.
        let bottomTop = v.documentHeight - box.height
        let bottomWindow = v.visibleWindow(viewport: viewport(top: bottomTop, height: box.height))
        XCTAssertFalse(bottomWindow.isEmpty)
        for (bump, i) in bottomWindow.enumerated() {
            v.recordMeasured(v.height(at: i) + CGFloat(50 + bump), at: i)
        }

        let restored = v.restoredTop(for: topAnchor)
        XCTAssertEqual(restored, 0, accuracy: 0.001,
                       "nothing above the top anchor changed, so the top is still the top")
        XCTAssertEqual(v.visibleWindow(viewport: viewport(top: restored, height: box.height)),
                       topWindow,
                       "the same turns must come back after a trip to the bottom")
    }

    // MARK: - 7. Offsets agree with heights

    func testOffsetOfIndexEqualsTheRunningSumOfHeights() {
        let v = makeVirtualizer(uniformTurns(500))
        // Break uniformity so a bug that returns `index * height(at: 0)` fails.
        for i in stride(from: 0, to: 500, by: 3) {
            v.recordMeasured(v.height(at: i) + CGFloat(i % 97), at: i)
        }

        var running: CGFloat = 0
        for i in 0 ... 500 {
            XCTAssertEqual(v.offset(of: i), running, accuracy: 0.001,
                           "offset(of: \(i)) must be the sum of every height before it")
            if i < 500 { running += v.height(at: i) }
        }
        XCTAssertEqual(v.documentHeight, running, accuracy: 0.001)
        XCTAssertEqual(v.offset(of: 500), v.documentHeight, accuracy: 0.001)
    }

    func testIndexAtYAgreesWithOffsets() {
        let v = makeVirtualizer(uniformTurns(200))
        for i in stride(from: 0, to: 200, by: 7) {
            v.recordMeasured(v.height(at: i) + CGFloat(i % 53), at: i)
        }

        for i in 0 ..< 200 {
            let top = v.offset(of: i)
            let mid = top + v.height(at: i) / 2
            XCTAssertEqual(v.index(atY: mid), i,
                           "the midpoint of turn \(i) must hit-test to turn \(i)")
        }
    }

    // MARK: - 8. Splice

    func testSplicePreservesTheGeometryOfEverythingBeforeTheSpliceIndex() {
        var turns = uniformTurns(40)
        let v = makeVirtualizer(turns)
        for i in 0 ..< 15 {
            v.recordMeasured(500 + CGFloat(i), at: i)
        }
        let heightsBefore = (0 ..< 20).map { v.height(at: $0) }
        let offsetsBefore = (0 ... 20).map { v.offset(of: $0) }

        // Everything from 20 on is replaced with different content.
        for i in 20 ..< 40 {
            turns[i] = uniformTurn(i + 5_000, bodyCharacters: 400)
        }
        v.splice(turns: turns, from: 20)

        for i in 0 ..< 20 {
            XCTAssertEqual(v.height(at: i), heightsBefore[i], accuracy: 0.001,
                           "turn \(i) is before the splice and must not have moved")
        }
        for i in 0 ... 20 {
            XCTAssertEqual(v.offset(of: i), offsetsBefore[i], accuracy: 0.001,
                           "offset \(i) is before the splice and must not have moved")
        }
        for i in 0 ..< 15 {
            XCTAssertTrue(v.isHeightExact(at: i),
                          "turn \(i) kept its identity, its view, and therefore its measurement")
        }
    }

    func testSpliceKeepsMeasurementsForTurnsAfterTheSpliceThatDidNotChange() {
        var turns = uniformTurns(40)
        let v = makeVirtualizer(turns)
        v.recordMeasured(777, at: 25)
        v.recordMeasured(888, at: 30)

        // The splice re-delivers turns 20..<40 unchanged and appends five more.
        turns.append(contentsOf: (40 ..< 45).map { uniformTurn($0) })
        v.splice(turns: turns, from: 20)

        XCTAssertEqual(v.height(at: 25), 777, accuracy: 0.001,
                       "an unchanged turn must not throw away a height that is still valid")
        XCTAssertEqual(v.height(at: 30), 888, accuracy: 0.001)
        XCTAssertTrue(v.isHeightExact(at: 25))
        XCTAssertEqual(v.count, 45)
    }

    func testSpliceDoesNotHandAnOldTurnsMeasuredHeightToADifferentTurn() {
        var turns = uniformTurns(40)
        let v = makeVirtualizer(turns)
        v.recordMeasured(777, at: 25)

        // Slot 25 now holds a different record entry entirely.
        turns[25] = uniformTurn(5_025, bodyCharacters: 9_000)
        v.splice(turns: turns, from: 20)

        XCTAssertNotEqual(v.height(at: 25), 777,
                          "a height measured for one turn is not a measurement of another")
        XCTAssertFalse(v.isHeightExact(at: 25),
                       "a turn that has never been laid out cannot claim an exact height")
    }

    func testSpliceThatShortensTheListLeavesConsistentGeometry() {
        let turns = uniformTurns(40)
        let v = makeVirtualizer(turns)

        let shortened = Array(turns.prefix(25))
        v.splice(turns: shortened, from: 20)

        XCTAssertEqual(v.count, 25)
        var running: CGFloat = 0
        for i in 0 ..< 25 { running += v.height(at: i) }
        XCTAssertEqual(v.documentHeight, running, accuracy: 0.001)
        assertInBounds(v.visibleWindow(viewport: viewport(top: 0, height: 600)), count: 25)
    }

    // MARK: - 9. Append and refresh

    func testAppendKeepsTheDocumentHeightConsistent() {
        let v = makeVirtualizer(uniformTurns(10))
        var expected = v.documentHeight

        for i in 10 ..< 40 {
            let turn = uniformTurn(i)
            v.append(turn)
            expected += v.height(at: v.count - 1)
            XCTAssertEqual(v.count, i + 1)
            XCTAssertEqual(v.documentHeight, expected, accuracy: 0.001,
                           "the document must grow by exactly the appended turn's height")
            XCTAssertEqual(v.offset(of: v.count), v.documentHeight, accuracy: 0.001)
        }

        var running: CGFloat = 0
        for i in 0 ..< v.count { running += v.height(at: i) }
        XCTAssertEqual(v.documentHeight, running, accuracy: 0.001)
    }

    func testAppendedTurnIsHitTestableAndAnchorable() {
        let v = makeVirtualizer(uniformTurns(10))
        let turn = uniformTurn(99)
        v.append(turn)

        let top = v.offset(of: 10)
        XCTAssertEqual(v.index(atY: top + v.height(at: 10) / 2), 10)
        guard let anchor = v.captureAnchor(viewportTop: top) else {
            return XCTFail("an appended turn must be anchorable")
        }
        XCTAssertEqual(anchor.key, turn.contentKey,
                       "a freshly appended turn must be reachable by the anchor's content key")
        XCTAssertEqual(v.restoredTop(for: anchor), top, accuracy: 0.001)
    }

    func testRefreshReportsTheDocumentDeltaWhenAStreamingTurnGrows() {
        var turns = uniformTurns(30)
        let v = makeVirtualizer(turns)

        let index = 29
        let documentWas = v.documentHeight
        let heightWas   = v.height(at: index)

        // The streaming turn gains a large text block.
        var grown = turns[index]
        grown.blocks.append(.text(String(repeating: "z", count: 6_000)))
        turns[index] = grown

        let delta = v.refresh(grown, at: index)

        XCTAssertGreaterThan(delta, 0, "adding six thousand characters must make the turn taller")
        XCTAssertEqual(v.height(at: index), heightWas + delta, accuracy: 0.001)
        XCTAssertEqual(v.documentHeight, documentWas + delta, accuracy: 0.001,
                       "refresh must report exactly the document delta it caused")
    }

    func testRefreshOfAnUnchangedTurnReportsNoDelta() {
        let turns = uniformTurns(30)
        let v = makeVirtualizer(turns)
        let documentWas = v.documentHeight

        XCTAssertEqual(v.refresh(turns[5], at: 5), 0, accuracy: 0.001)
        XCTAssertEqual(v.documentHeight, documentWas, accuracy: 0.001)
    }

    func testRefreshOutsideTheListIsANoOp() {
        let turns = uniformTurns(5)
        let v = makeVirtualizer(turns)
        let documentWas = v.documentHeight

        XCTAssertEqual(v.refresh(turns[0], at: -1), 0)
        XCTAssertEqual(v.refresh(turns[0], at: 5), 0)
        XCTAssertEqual(v.refresh(turns[0], at: 9_999), 0)
        XCTAssertEqual(v.documentHeight, documentWas, accuracy: 0.001)
    }

    func testRefreshDoesNotStrandTheAnchorOfATurnThatIsStillStreaming() {
        var turns = uniformTurns(60)
        let v = makeVirtualizer(turns)

        let viewportTop = v.offset(of: 40) + 12
        guard let anchor = v.captureAnchor(viewportTop: viewportTop) else {
            return XCTFail("a non-empty transcript must yield an anchor")
        }
        XCTAssertEqual(anchor.index, 40)

        // A turn *below* the anchor keeps streaming.
        var grown = turns[50]
        grown.blocks.append(.text(String(repeating: "z", count: 4_000)))
        turns[50] = grown
        v.refresh(grown, at: 50)

        XCTAssertEqual(v.restoredTop(for: anchor), viewportTop, accuracy: 1.0,
                       "growth below the reading position must not move it")
    }

    // MARK: - 10. Degenerate input

    func testEmptyTranscriptAnswersEverythingWithoutCrashing() {
        let v = makeVirtualizer([])

        XCTAssertEqual(v.count, 0)
        XCTAssertEqual(v.documentHeight, 0, accuracy: 0.001)
        XCTAssertEqual(v.visibleWindow(viewport: viewport(top: 0, height: 600)), 0 ..< 0)
        XCTAssertEqual(v.visibleWindow(viewport: viewport(top: 10_000, height: 600)), 0 ..< 0)
        XCTAssertEqual(v.index(atY: 0), 0)
        XCTAssertEqual(v.index(atY: 5_000), 0)
        XCTAssertEqual(v.offset(of: 0), 0, accuracy: 0.001)
        XCTAssertEqual(v.height(at: 0), 0, accuracy: 0.001)
        XCTAssertNil(v.captureAnchor(viewportTop: 0),
                     "there is no position to hold in an empty transcript")
        XCTAssertEqual(v.recordMeasured(100, at: 0), 0)
    }

    func testSingleTurnTranscript() {
        let v = makeVirtualizer([uniformTurn(0)])

        XCTAssertEqual(v.count, 1)
        XCTAssertGreaterThan(v.documentHeight, 0)
        let window = v.visibleWindow(viewport: viewport(top: 0, height: 600))
        XCTAssertEqual(window, 0 ..< 1)
        assertInBounds(window, count: 1)
        XCTAssertEqual(v.index(atY: -50), 0)
        XCTAssertEqual(v.index(atY: v.documentHeight * 10), 0)
        XCTAssertEqual(v.offset(of: 1), v.documentHeight, accuracy: 0.001)

        guard let anchor = v.captureAnchor(viewportTop: 5) else {
            return XCTFail("a one-turn transcript still has a position")
        }
        XCTAssertEqual(anchor.index, 0)
        XCTAssertEqual(v.restoredTop(for: anchor), 5, accuracy: 0.001)
    }

    func testViewportTallerThanTheWholeDocumentMaterializesEverything() {
        let v = makeVirtualizer(uniformTurns(12))
        let window = v.visibleWindow(viewport: viewport(top: 0, height: v.documentHeight * 4))

        XCTAssertEqual(window, 0 ..< 12)
        assertInBounds(window, count: 12)
    }

    func testViewportScrolledPastTheEndStaysInBounds() {
        let v = makeVirtualizer(uniformTurns(40))
        let past = v.documentHeight * 3

        for top in [v.documentHeight, past, past * 10] {
            let window = v.visibleWindow(viewport: viewport(top: top, height: 600))
            assertInBounds(window, count: 40, "top \(top):")
            XCTAssertFalse(window.isEmpty, "a window past the end must still name a real turn")
            XCTAssertEqual(v.index(atY: top), 39,
                           "hit-testing past the end must clamp to the last turn")
        }
    }

    func testViewportScrolledBeforeTheStartStaysInBounds() {
        let v = makeVirtualizer(uniformTurns(40))
        let window = v.visibleWindow(viewport: viewport(top: -5_000, height: 600))

        assertInBounds(window, count: 40)
        XCTAssertEqual(window.lowerBound, 0)
        XCTAssertEqual(v.index(atY: -5_000), 0)
    }

    func testZeroSizedViewportStaysInBounds() {
        let v = makeVirtualizer(uniformTurns(40))
        let window = v.visibleWindow(viewport: CGRect(x: 0, y: 1_000, width: 0, height: 0))
        assertInBounds(window, count: 40)
    }

    func testOutOfBoundsIndicesAreAnsweredRatherThanTrapped() {
        let v = makeVirtualizer(uniformTurns(10))

        XCTAssertEqual(v.height(at: -1), 0)
        XCTAssertEqual(v.height(at: 10), 0)
        XCTAssertFalse(v.isHeightExact(at: -1))
        XCTAssertFalse(v.isHeightExact(at: 10))
        XCTAssertEqual(v.offset(of: -1), 0, accuracy: 0.001)
        XCTAssertEqual(v.offset(of: 999), v.documentHeight, accuracy: 0.001)
        XCTAssertEqual(v.recordMeasured(50, at: -1), 0)
        XCTAssertEqual(v.recordMeasured(50, at: 10), 0)
    }

    func testAnchorForATurnThatLeftTheTranscriptStillLandsInsideTheDocument() {
        let v = makeVirtualizer(uniformTurns(40))
        guard let anchor = v.captureAnchor(viewportTop: v.offset(of: 35)) else {
            return XCTFail("a non-empty transcript must yield an anchor")
        }

        v.reset(turns: uniformTurns(3), width: Self.paneWidth)

        let restored = v.restoredTop(for: anchor)
        XCTAssertGreaterThanOrEqual(restored, 0)
        XCTAssertLessThanOrEqual(restored, v.documentHeight,
                                 "a vanished anchor must clamp into the document, not past it")
    }

    func testResetWithZeroWidthDoesNotProduceDegenerateGeometry() {
        let v = TurnListVirtualizer()
        v.reset(turns: uniformTurns(5), width: 0)

        XCTAssertGreaterThan(v.documentHeight, 0)
        for i in 0 ..< 5 {
            XCTAssertGreaterThan(v.height(at: i), 0, "turn \(i) must never be zero-height")
        }
        assertInBounds(v.visibleWindow(viewport: viewport(top: 0, height: 600)), count: 5)
    }
}
