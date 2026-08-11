import XCTest
import CoreGraphics
// ChatTurn, TurnBlock, TurnHeightEstimator and TurnPayloadStore are compiled
// into this target directly (logic test — no host app). No module imports needed.

// MARK: - TurnHeightEstimatorTests

/// Behavioural tests for `TurnHeightEstimator`.
///
/// The estimator's job is not to be right. It is to be *usefully wrong*: cheap
/// enough to run for five thousand turns on every resize, and close enough that
/// the scrollbar is believable and the correction to the real measured height is
/// small. So these tests assert the properties the transcript actually depends
/// on — monotonicity, never-zero, width behaviour, and the invariance that lets a
/// compacted turn hold its place — plus one loose sanity table.
///
/// Deliberately no real views are measured. The test target has no window, and a
/// test that built `NSTextView`s to check an estimator would be measuring exactly
/// the thing the estimator exists to avoid.
final class TurnHeightEstimatorTests: XCTestCase {

    // MARK: - Fixtures

    private static let paneWidth: CGFloat = 800

    private func text(_ n: Int) -> String { String(repeating: "a", count: n) }

    private func turn(user: String = "", blocks: [TurnBlock] = []) -> ChatTurn {
        ChatTurn(userInput:    user,
                 timestamp:    Date(timeIntervalSince1970: 1_770_000_000),
                 timestampRaw: "2026-08-11T12:00:00.0000Z",
                 blocks:       blocks,
                 isComplete:   true,
                 daemonId:     "t0",
                 epoch:        0)
    }

    private func estimate(_ t: ChatTurn, width: CGFloat = TurnHeightEstimatorTests.paneWidth) -> CGFloat {
        TurnHeightEstimator.estimate(t, width: width)
    }

    /// One representative turn per block kind, parameterised by content length,
    /// so the same property can be swept across every kind the transcript
    /// renders.
    private enum Kind: String, CaseIterable {
        case text, toolCall, toolResult, toolResultError, resultSummary, errorMessage, askQuestion

        /// True for kinds whose rendered height is supposed to track content
        /// length. The rest are fixed-height rows by design.
        var wrapsItsContent: Bool {
            switch self {
            case .text, .toolResultError, .errorMessage, .askQuestion: return true
            case .toolCall, .toolResult, .resultSummary:               return false
            }
        }
    }

    private func block(_ kind: Kind, characters: Int) -> TurnBlock {
        let body = text(characters)
        switch kind {
        case .text:
            return .text(body)
        case .toolCall:
            return .toolCall(ToolCallData(toolName: "Bash", inputSummary: body, inputFull: body))
        case .toolResult:
            return .toolResult(ToolResultData(content: body, isError: false))
        case .toolResultError:
            return .toolResult(ToolResultData(content: body, isError: true))
        case .resultSummary:
            return .resultSummary(ResultSummaryData(durationMs: 1_200, costUSD: 0.02, isError: false))
        case .errorMessage:
            return .errorMessage(body)
        case .askQuestion:
            return .askQuestion(AskQuestionData(
                question: body,
                header:   "Decision",
                options:  [AskQuestionData.Option(label: "Yes", description: "do it"),
                           AskQuestionData.Option(label: "No",  description: "don't")],
                multiSelect: false))
        }
    }

    // MARK: - 1. Monotonic in content length

    func testEstimatesNeverShrinkAsContentGrows() {
        let lengths = [1, 10, 80, 200, 512, 1_000, 4_000, 20_000, 260_000]

        for kind in Kind.allCases {
            var previous: CGFloat = 0
            for n in lengths {
                let height = estimate(turn(blocks: [block(kind, characters: n)]))
                XCTAssertGreaterThanOrEqual(
                    height, previous,
                    "\(kind.rawValue) got shorter when its content grew to \(n) characters")
                previous = height
            }
        }
    }

    func testTextWrappingBlocksGetTallerAsContentGrows() {
        for kind in Kind.allCases where kind.wrapsItsContent {
            let small = estimate(turn(blocks: [block(kind, characters: 100)]))
            let large = estimate(turn(blocks: [block(kind, characters: 10_000)]))
            XCTAssertGreaterThan(
                large, small,
                "\(kind.rawValue) renders its content, so a hundred times more of it must be taller")
        }
    }

    func testAUserMessageNeverGetsShorterAsItGrows() {
        var previous: CGFloat = 0
        for n in stride(from: 1, through: 4_000, by: 13) {
            let height = estimate(turn(user: text(n)))
            XCTAssertGreaterThanOrEqual(height, previous,
                                        "a \(n)-character message got shorter")
            previous = height
        }
    }

    func testAUserMessageGetsTallerAsItWrapsOntoMoreLines() {
        // Line height is quantised — 1 and 40 characters are both one line — so
        // the sample lengths have to actually cross wrap boundaries.
        var previous: CGFloat = 0
        for n in [1, 200, 900, 5_000, 30_000] {
            let height = estimate(turn(user: text(n)))
            XCTAssertGreaterThan(height, previous, "a \(n)-character message must be taller")
            previous = height
        }
    }

    func testMoreBlocksIsNeverShorterThanFewer() {
        var blocks: [TurnBlock] = []
        var previous: CGFloat = 0
        for kind in Kind.allCases {
            blocks.append(block(kind, characters: 300))
            let height = estimate(turn(user: text(120), blocks: blocks))
            XCTAssertGreaterThan(height, previous,
                                 "appending a \(kind.rawValue) block must not shrink the turn")
            previous = height
        }
    }

    // MARK: - 2. Never zero

    func testNoNonEmptyTurnEverEstimatesZero() {
        for kind in Kind.allCases {
            for n in [1, 5, 512, 100_000] {
                for width in [1 as CGFloat, 20, 200, 800, 4_000] {
                    let height = estimate(turn(blocks: [block(kind, characters: n)]), width: width)
                    XCTAssertGreaterThanOrEqual(
                        height, TurnHeightEstimator.minimumTurnHeight,
                        "\(kind.rawValue) at \(n) chars / \(width) pt collapsed the document")
                }
            }
        }
    }

    func testEvenAnEmptyTurnHasHeight() {
        // A zero-height turn would make every offset after it meaningless.
        XCTAssertGreaterThanOrEqual(estimate(turn()), TurnHeightEstimator.minimumTurnHeight)
        XCTAssertGreaterThanOrEqual(estimate(turn(), width: 1),
                                    TurnHeightEstimator.minimumTurnHeight)
    }

    func testWrappedHeightIsNeverZeroForNonEmptyText() {
        for characters in [1, 2, 999, 500_000] {
            for width in [1 as CGFloat, 3, 50, 617, 2_000] {
                let h = TurnHeightEstimator.wrappedHeight(characters: characters,
                                                          width: width,
                                                          glyphWidth: TurnHeightEstimator.systemGlyphWidth,
                                                          lineHeight: TurnHeightEstimator.bodyLineHeight)
                XCTAssertGreaterThanOrEqual(h, TurnHeightEstimator.bodyLineHeight,
                                            "\(characters) chars at \(width) pt wrapped to nothing")
            }
        }
    }

    func testWrappedHeightIsZeroOnlyForEmptyText() {
        XCTAssertEqual(TurnHeightEstimator.wrappedHeight(characters: 0, width: 600,
                                                         glyphWidth: 6.6, lineHeight: 16), 0)
    }

    // MARK: - 3. Monotonic (non-increasing) in width

    func testANarrowerPaneNeverMakesATurnShorter() {
        let samples: [(String, ChatTurn)] = [
            ("plain message",  turn(user: text(400))),
            ("message + prose", turn(user: text(200), blocks: [block(.text, characters: 3_000)])),
            ("tool sequence",  turn(user: text(90), blocks: [
                block(.text, characters: 700),
                block(.toolCall, characters: 60),
                block(.toolResultError, characters: 5_000),
                block(.resultSummary, characters: 0)])),
            ("question card",  turn(blocks: [block(.askQuestion, characters: 600)])),
            ("error",          turn(blocks: [block(.errorMessage, characters: 2_400)])),
        ]

        for (label, t) in samples {
            var widths = Array(stride(from: CGFloat(1_400), through: 200, by: -25))
            widths.append(contentsOf: [120, 60, 10, 1])
            var previous = estimate(t, width: widths[0])
            for width in widths.dropFirst() {
                let height = estimate(t, width: width)
                XCTAssertGreaterThanOrEqual(
                    height, previous,
                    "\(label): narrowing the pane to \(width) pt made the turn shorter")
                previous = height
            }
        }
    }

    func testHalvingThePaneWidthMakesAProseTurnMeaningfullyTaller() {
        // Not just non-decreasing — the estimate has to actually respond to
        // width, or a resize would leave every offset in the document wrong.
        let t = turn(user: text(200), blocks: [block(.text, characters: 6_000)])
        XCTAssertGreaterThan(estimate(t, width: 400), estimate(t, width: 800) * 1.5,
                             "halving the width roughly doubles the line count of wrapped prose")
    }

    // MARK: - 4. Collapsed rows cost a fixed height; errors do not

    func testACollapsedToolResultCostsTheSameNoMatterHowLargeThePayloadIs() {
        let tiny  = estimate(turn(blocks: [block(.toolResult, characters: 20)]))
        let huge  = estimate(turn(blocks: [block(.toolResult, characters: 512_000)]))

        XCTAssertEqual(tiny, huge, accuracy: 0.001,
                       "a collapsed result shows a disclosure row, not half a megabyte of diff")
        XCTAssertEqual(TurnHeightEstimator.estimate(block: block(.toolResult, characters: 512_000),
                                                    characters: 512_000,
                                                    width: 642),
                       TurnHeightEstimator.toolResultCollapsed, accuracy: 0.001)
    }

    func testAnErroredToolResultIsOpenByDefaultAndSoTracksItsPayload() {
        let tiny = estimate(turn(blocks: [block(.toolResultError, characters: 20)]))
        let big  = estimate(turn(blocks: [block(.toolResultError, characters: 20_000)]))

        XCTAssertGreaterThan(big, tiny * 10,
                             "an error result opens by default, so its height must follow its content")
    }

    func testAToolCallRowCostsTheSameNoMatterHowLongItsSummaryIs() {
        let short = estimate(turn(blocks: [block(.toolCall, characters: 5)]))
        let long  = estimate(turn(blocks: [block(.toolCall, characters: 5_000)]))
        XCTAssertEqual(short, long, accuracy: 0.001,
                       "the collapsed tool-call row is one line of 11 pt text")
    }

    // MARK: - 5. Markers

    func testMarkerTurnsEstimateTheMarkerHeight() {
        for marker in [ChatTurn.Marker.gap, .historyUnavailable] {
            for width in [200 as CGFloat, 800, 2_000] {
                XCTAssertEqual(estimate(ChatTurn.marker(marker), width: width),
                               TurnHeightEstimator.markerHeight, accuracy: 0.001,
                               "\(marker) is a fixed statement row, not a chat exchange")
            }
        }
    }

    func testAMarkerIsNotChargedForContentItDoesNotRender() {
        var marker = ChatTurn.marker(.gap)
        marker.userInput = text(9_000)
        marker.blocks    = [block(.text, characters: 40_000)]

        XCTAssertEqual(estimate(marker), TurnHeightEstimator.markerHeight, accuracy: 0.001)
    }

    // MARK: - 6. A compacted turn holds its place

    /// The property that makes bounded memory survivable: once `TurnPayloadStore`
    /// has swapped a turn's text for a 512-character prefix, the estimator must
    /// still believe the turn is as tall as it was. Otherwise every cold turn in
    /// the transcript shrinks to three lines and the scroll document collapses
    /// underneath the operator.
    func testASkeletonEstimatesTheSameHeightAsTheTurnItWasMadeFrom() {
        let full = turn(user: text(4_000), blocks: [
            block(.text, characters: 9_000),
            block(.toolCall, characters: 900),
            block(.toolResult, characters: 300_000),
            block(.toolResultError, characters: 22_000),
            block(.resultSummary, characters: 0),
            block(.errorMessage, characters: 3_100),
            block(.askQuestion, characters: 700),
            block(.text, characters: 40),
        ])
        let skeleton = TurnPayloadStore.skeleton(of: full)

        XCTAssertNotNil(skeleton.truncatedLengths, "fixture must actually have been truncated")
        XCTAssertLessThan(skeleton.userInput.count, full.userInput.count)

        for width in [320 as CGFloat, 500, 800, 1_600] {
            XCTAssertEqual(estimate(skeleton, width: width), estimate(full, width: width),
                           accuracy: 0.5,
                           "a compacted turn must hold exactly its old place at \(width) pt")
        }
    }

    func testASkeletonWithoutItsRecordedLengthsWouldCollapse() {
        // Establishes that the previous test is load-bearing rather than
        // vacuous: the surviving prefix on its own is dramatically shorter.
        let full = turn(user: text(4_000), blocks: [block(.text, characters: 40_000)])
        var amnesiac = TurnPayloadStore.skeleton(of: full)
        amnesiac.truncatedLengths = nil

        XCTAssertLessThan(estimate(amnesiac), estimate(full) / 4,
                          "if this is not much shorter, the skeleton test proves nothing")
    }

    func testEachBlockKindSurvivesCompactionAtTheSameHeight() {
        for kind in Kind.allCases {
            let full = turn(user: text(1_500), blocks: [block(kind, characters: 30_000)])
            let skeleton = TurnPayloadStore.skeleton(of: full)
            XCTAssertEqual(estimate(skeleton), estimate(full), accuracy: 0.5,
                           "\(kind.rawValue) changed height when it was compacted")
        }
    }

    // MARK: - 7. Sanity table

    /// A handful of turns whose expected height was worked out by hand from the
    /// calibration constants documented at the top of `TurnHeightEstimator`, at
    /// a 800 pt pane (bubble 800×0.75−24 = 576 pt, blocks 800×0.82−14 = 642 pt).
    ///
    /// ±25 % — this is a sanity check on the calibration, not a golden-file test.
    /// A tighter bound would break every time somebody adjusts a padding
    /// constant, which is a change the estimator is allowed to make.
    func testEstimatesLandNearHandComputedHeights() {
        // 26 chrome + 24 bubble + ceil(120/87)=2 lines × 16
        assertNear(turn(user: text(120)), expected: 82, label: "short message, no reply")

        // 26 + 24 + 3×16   +   card 24 + ceil(1500/93)=17 lines × 16
        assertNear(turn(user: text(200), blocks: [block(.text, characters: 1_500)]),
                   expected: 394, label: "message + one prose reply")

        // 26 + 24 + 1×16  +  (24 + 7×16)  +  (6+30)  +  (6+32)  +  (6+14)
        assertNear(turn(user: text(80), blocks: [
                        block(.text, characters: 600),
                        block(.toolCall, characters: 40),
                        block(.toolResult, characters: 40_000),
                        block(.resultSummary, characters: 0)]),
                   expected: 296, label: "message + prose + collapsed tool round trip")

        // 26 + (46 chrome + 2 options × 36 + ceil(90/93)=1 line × 16)
        assertNear(turn(blocks: [block(.askQuestion, characters: 90)]),
                   expected: 160, label: "question card")

        // 26 + (32 collapsed + ceil(2000/107)=19 mono lines × 14)
        assertNear(turn(blocks: [block(.toolResultError, characters: 2_000)]),
                   expected: 324, label: "opened error result")
    }

    private func assertNear(_ t: ChatTurn, expected: CGFloat, label: String,
                            file: StaticString = #filePath, line: UInt = #line) {
        let actual = estimate(t)
        XCTAssertEqual(actual, expected, accuracy: expected * 0.25,
                       "\(label): estimated \(actual) pt against a hand-computed \(expected) pt",
                       file: file, line: line)
    }
}
