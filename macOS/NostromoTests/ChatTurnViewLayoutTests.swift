import XCTest
import AppKit

// ChatTurnView, MarkerTurnView, MarkdownTableView, TextBlockView,
// ToolCallView, ResultChipView, ErrorBlockView, UserBubbleView, TurnIsland,
// WidthPresettable, ToolResultView, AskQuestionView, TurnInteractionState,
// ChatTurn, TurnBlock, TurnHeightEstimator are compiled into this target
// directly (logic test — no host app, no `@testable import`). `ReplView`
// itself is not: it pulls in `ChatSession`/`AppStore`/the daemon client
// stack and needs a real window to mean anything — see `ChatTurnView.swift`'s
// header for why the turn/block views were extracted so this file could exist.

// MARK: - Shared view-hierarchy helpers

/// Depth-first search for the first descendant of `type` under `view`,
/// including `view`'s own subviews but not `view` itself. Same pattern as
/// `TurnInteractionTests.swift`'s helper of the same name — file-scoped
/// `private`, so the duplicate declaration is not a conflict. Used instead of
/// exposing internal accessors: the membrane these tests enforce is "what
/// AppKit's own view hierarchy says", not the view's private layout state.
private func firstDescendant<T>(of type: T.Type, in view: NSView) -> T? {
    for sub in view.subviews {
        if let match = sub as? T { return match }
        if let found = firstDescendant(of: type, in: sub) { return found }
    }
    return nil
}

// MARK: - ChatTurnViewLayoutTests

/// Regression tests for the 2026-09-09 main-thread freeze: `ReplView.measure()`
/// was superlinear in the number of Auto Layout–constrained subviews inside a
/// single turn. A 400-row markdown table took 3.5 minutes to measure once, and
/// streaming one turn to 300 blocks cost 80 s of cumulative main-thread time —
/// the app beachballed permanently. The fix (see `ChatTurnView.swift` and
/// `MarkdownTableView.swift`'s headers for the full argument and the measured
/// before/after numbers) is architectural: a table holds zero Auto Layout
/// constraints and is frame-positioned from `layout()`, and a turn's blocks are
/// each an independent, frame-positioned "island" holding exactly one
/// constraint of their own — their width — linked to nothing else. Heights are
/// measured per-island, cached, and summed, rather than solved as one
/// connected constraint graph.
///
/// These tests are the contract that keeps that fix a fix:
///
///  1. `MarkdownTableView` holds a *constant* number of constraints (zero),
///     independent of row and column count.
///  2. `ChatTurnView`'s constraint count is bounded linearly in block count,
///     and — the assertion that actually distinguishes "an island" from "a
///     smaller shared graph" — no constraint anywhere in the subtree links two
///     different islands.
///  3. A table of golden fixtures pins the *rendered* height of every block
///     kind, alone and in combination, against the pre-fix implementation's
///     own output — because the point of a rewrite like this is that nothing
///     about what the operator sees is allowed to change.
///  4. The turn's total height is exactly its chrome plus its bubble plus its
///     summed block heights — the arithmetic identity that has to hold for
///     `TurnHeightEstimator`'s calibration constants to still describe reality.
///  5. Streaming a turn block-by-block lands on exactly the height of building
///     it in one shot — the property that makes incremental measurement during
///     live streaming safe.
///  6. Expanding one tool result changes only that block's contribution.
///  7. A pane-width change actually re-measures, so a resize can never leave a
///     stale cached height behind — which, for a completed turn, would be
///     permanent.
///
/// Nothing here asserts on wall-clock time. `TurnListVirtualizerTests`' header
/// explains why: timing is flaky on a shared machine and doesn't actually
/// distinguish the fixed shape from the broken one as precisely as counting
/// constraints and checking arithmetic does.
final class ChatTurnViewLayoutTests: XCTestCase {

    // MARK: - Constraint-graph helpers

    /// Every constraint held anywhere in `view`'s subtree, `view` included.
    /// `NSLayoutConstraint.activate` adds a constraint to the nearest common
    /// ancestor of the views it relates, so walking every view's own
    /// `.constraints` array top-down finds all of them exactly once.
    private func countConstraints(_ view: NSView) -> Int {
        view.constraints.count + view.subviews.reduce(0) { $0 + countConstraints($1) }
    }

    private func allConstraints(in view: NSView) -> [NSLayoutConstraint] {
        view.constraints + view.subviews.flatMap { allConstraints(in: $0) }
    }

    /// Which "island" `view` belongs to under `turn`: `turn` itself, or the
    /// direct child of `turn` that `view` descends from (a block view, or the
    /// bubble). Two views are in the same island exactly when this returns the
    /// same identity for both.
    private func islandID(of view: NSView, under turn: ChatTurnView) -> ObjectIdentifier {
        if view === turn { return ObjectIdentifier(turn) }
        var current = view
        while let superview = current.superview, superview !== turn {
            current = superview
        }
        return ObjectIdentifier(current)
    }

    /// Measures the way `ReplView.measure()` does: tell the island the pane
    /// width, then ask its height at that width.
    private func measuredHeight(_ island: TurnIsland, paneWidth: CGFloat = 900) -> CGFloat {
        island.setIslandWidth(paneWidth)
        return island.islandHeight()
    }

    /// Plain paragraph text with no markdown markers (`#`, `-`, `` ` ``, `**`,
    /// `\n---`), so it always takes `TextBlockView`'s single-label path rather
    /// than routing to `MarkdownCardView` — irrelevant to the constraint-count
    /// tests, which only care that block count scales linearly, not which
    /// rendering path a block takes.
    private func plainTextBlocks(_ n: Int) -> [TurnBlock] {
        (0..<n).map { .text("block \($0) plain text content for layout testing purposes") }
    }

    // MARK: - 1. MarkdownTableView holds a constant number of constraints

    /// Pre-fix, a table was built entirely from Auto Layout: a chained
    /// `row.top == previous.bottom` between rows, and per cell a
    /// `leading == previous.trailing`, a `width == labels[0].width`
    /// back-reference, and a `centerY` — about 23 constraints per row.
    /// Measured against the real view at a 900 pt pane, a 400-row × 6-col
    /// table carried roughly 9 200 constraints and one `measure()` call took
    /// three and a half minutes. The fix holds zero, always: rows and cells
    /// are frame-positioned from `layout()`. These assert the count is a true
    /// constant — independent of both row count and column count — not merely
    /// "smaller than before".
    func testMarkdownTableViewConstraintCountIsIndependentOfRowCount() {
        let tiny = MarkdownTableView(headers: ["a", "b"], rows: [["1", "2"]])
        let huge = MarkdownTableView(headers: (0..<6).map { "h\($0)" },
                                     rows: (0..<400).map { r in (0..<6).map { "r\(r)c\($0)" } })

        XCTAssertEqual(countConstraints(tiny), countConstraints(huge),
                       "a 1x2 table and a 400x6 table must hold the same total constraint count")
        XCTAssertEqual(countConstraints(huge), 0,
                       "MarkdownTableView must hold zero Auto Layout constraints — pre-fix, a " +
                       "400-row x 6-col table carried roughly 9 200 (about 23 per row)")
    }

    func testMarkdownTableViewConstraintCountIsIndependentOfColumnCount() {
        let narrow = MarkdownTableView(headers: ["a"], rows: [["1"], ["2"]])
        let wide = MarkdownTableView(headers: (0..<20).map { "h\($0)" },
                                     rows: [(0..<20).map { "r0c\($0)" }])

        XCTAssertEqual(countConstraints(narrow), countConstraints(wide),
                       "a 1-column table and a 20-column table must hold the same total constraint count")
        XCTAssertEqual(countConstraints(wide), 0)
    }

    func testMarkdownTableViewHeightIsHeaderPlusRowsTimesRowHeight() {
        for rowCount in [0, 1, 5, 12, 400] {
            let table = MarkdownTableView(headers: ["a", "b"],
                                          rows: (0..<rowCount).map { ["r\($0)a", "r\($0)b"] })
            let expected: CGFloat = 30 + 26 * CGFloat(rowCount)
            XCTAssertEqual(table.intrinsicContentSize.height, expected, accuracy: 0.001,
                           "\(rowCount) rows: expected header row (30) + rowCount * body row (26), " +
                           "including the header-only 0-row case")
        }
    }

    func testMarkdownTableViewWithNoColumnsHasZeroHeightRatherThanCrashing() {
        // `headers: [], rows: []` alone does *not* reach the zero-column path:
        // `colCount` is `max(headers.count, tableRows.map { $0.count }.max() ?? 1)`,
        // and an empty `tableRows` makes `.max()` nil, which the `?? 1` fallback
        // turns into a phantom single column (a 30 pt header-only table) rather
        // than zero. The genuinely columnless case — the one the `guard colCount
        // > 0` branch exists for — is a row that itself has zero cells, which
        // makes `.max()` resolve to a real `0` and bypass the fallback.
        let table = MarkdownTableView(headers: [], rows: [[]])
        XCTAssertEqual(table.intrinsicContentSize.height, 0,
                       "a table with no columns at all renders nothing and must not crash computing it")
    }

    // MARK: - 2. ChatTurnView blocks are islands

    /// Pre-fix, this failed two independent ways: every block carried its own
    /// `v.widthAnchor == blocksStack.widthAnchor` constraint back to a shared
    /// `NSStackView`, and the stack itself chained each arranged subview's
    /// `top == previous.bottom` to the one before it. Together that made one
    /// turn's blocks a single connected constraint graph, which is exactly
    /// what made the solve superlinear in the turn's size — the same shape as
    /// `MarkdownTableView`'s pre-fix rows, one level up. The fix gives every
    /// block exactly one constraint — its own width, `equalToConstant` — with
    /// nothing tying it to a sibling or to a shared container.
    func testChatTurnViewConstraintCountIsBoundedLinearlyInBlockCount() {
        let blockCount = 400
        let turn = ChatTurn(userInput: "hi", timestamp: Date(),
                            blocks: plainTextBlocks(blockCount), isComplete: true)
        let view = ChatTurnView(turn: turn, contentAvailable: true, interaction: TurnInteractionState())
        _ = measuredHeight(view)

        let total = countConstraints(view)
        // Measured against the real view at a 900 pt pane, after measuring —
        // exactly 10n + 11, checked at n = 0, 1, 100, 200 and 400:
        //
        //   5 per block that the block itself holds: its own width constraint
        //     (`equalToConstant`, the one constraint an island is allowed) plus
        //     `TextBlockView`'s four internal pins on its one label.
        //   5 per block that AppKit installs: the
        //     `NSAutoresizingMaskLayoutConstraint`s a
        //     `translatesAutoresizingMaskIntoConstraints = true` subview gets
        //     once the engine has actually been exercised. They appear only
        //     after the first measurement, which is why counting before one
        //     reports 5n and not 10n.
        //   11 fixed: the turn's own width constraint, the bubble's, and the
        //     bubble's internals.
        //
        // Note what this row is and is not. The *count* alone never
        // distinguished the fixed shape from the broken one — pre-fix, 400
        // blocks carried 2 012 constraints, fewer than now, and took 3 362 ms
        // to solve because they were one connected graph. This bound only
        // catches a return to per-block chaining that also inflates the count;
        // `testNoConstraintCrossesAnIslandBoundary` below is the assertion that
        // actually holds the fix. k = 12 leaves headroom over the measured 10
        // for an incidental subview change without hiding a doubling.
        let k = 12
        let c = 40
        XCTAssertLessThanOrEqual(total, k * blockCount + c,
                                 "\(blockCount) blocks carried \(total) constraints — " +
                                 "expected <= \(k) * blockCount + \(c)")
    }

    /// The assertion that actually distinguishes "independent islands" from
    /// "a smaller but still-connected graph". Two halves, and it needs both.
    ///
    /// **Every block is its own island.** Pre-fix the turn had exactly two
    /// direct subviews — the bubble and one `NSStackView` holding all four
    /// hundred blocks — so a partition defined by "direct subview of the turn"
    /// would have called that whole stack a single island and seen nothing
    /// wrong with the chaining inside it. Asserting the *number* of islands is
    /// what makes the partition below mean what it says.
    ///
    /// **No constraint crosses one.** Every constraint anywhere in the subtree
    /// must relate two views in the same island, or name only the
    /// `ChatTurnView` itself. Pre-fix this failed on the turn's own pins —
    /// `bubble.top == turn.top`, `blocksStack.top == bubble.bottom` — which is
    /// the same defect one level up: the bubble and the block column were
    /// solved together with the turn rather than independently of it.
    func testEveryBlockIsItsOwnIslandAndNoConstraintCrossesOne() {
        let blockCount = 400
        let turn = ChatTurn(userInput: "hi", timestamp: Date(),
                            blocks: plainTextBlocks(blockCount), isComplete: true)
        let view = ChatTurnView(turn: turn, contentAvailable: true, interaction: TurnInteractionState())
        _ = measuredHeight(view)

        XCTAssertEqual(view.subviews.count, blockCount + 1,
                       "the turn must hold one direct subview per block plus the user bubble — " +
                       "pre-fix it held 2, the bubble and an NSStackView containing every block")

        var violations: [String] = []
        for constraint in allConstraints(in: view) {
            guard let first = constraint.firstItem as? NSView,
                  let second = constraint.secondItem as? NSView else { continue }
            if islandID(of: first, under: view) != islandID(of: second, under: view) {
                violations.append("\(constraint)")
            }
        }
        XCTAssertTrue(violations.isEmpty,
                     "found \(violations.count) constraint(s) crossing an island boundary " +
                     "(first few: \(violations.prefix(3)))")
    }

    // MARK: - 3. Height parity — golden fixtures

    /// One fixture: a turn's shape, plus the height it must render at, with
    /// content available and with it truncated.
    ///
    /// The goldens were captured by rendering each of these against
    /// `origin/main`'s pre-fix `ChatTurnView`/`MarkdownTableView` — the
    /// `NSStackView` + per-row-constraint implementation — at a 900 pt pane.
    /// The whole point of this rewrite is that rendered geometry does not
    /// change even though the constraint graph underneath it is gone, so
    /// these numbers are also the post-fix heights. A mismatch here means a
    /// real rendered-geometry regression, not a broken test: do not loosen a
    /// golden to make it pass — report the fixture name and both numbers.
    private struct Fixture {
        let name: String
        let userInput: String
        let blocks: [TurnBlock]
        let expanded: [Int]
        let trueGolden: CGFloat
        let falseGolden: CGFloat
    }

    private static func text(_ n: Int) -> String {
        let unit = "the quick brown fox jumps over the lazy dog and keeps going "
        var s = ""
        while s.count < n { s += unit }
        return String(s.prefix(n))
    }

    private static func table(rows: Int, cols: Int) -> String {
        let hdr = "|" + (0..<cols).map { " h\($0) " }.joined(separator: "|") + "|"
        let sep = "|" + (0..<cols).map { _ in "---" }.joined(separator: "|") + "|"
        var lines = [hdr, sep]
        for r in 0..<rows {
            lines.append("|" + (0..<cols).map { " r\(r)c\($0) " }.joined(separator: "|") + "|")
        }
        return lines.joined(separator: "\n")
    }

    private static let fixtures: [Fixture] = [
        Fixture(name: "plain-text", userInput: "hello",
               blocks: [.text(text(240))], expanded: [],
               trueGolden: 114, falseGolden: 133),
        Fixture(name: "markdown-single-segment", userInput: "hello",
               blocks: [.text("## Heading\n\n- one\n- two\n\n" + text(300))], expanded: [],
               trueGolden: 196, falseGolden: 215),
        Fixture(name: "markdown-multi-segment", userInput: "hello",
               blocks: [.text("## A\n\n- " + text(200) + "\n---\n## B\n\n- " + text(200)
                              + "\n---\n## C\n\n- " + text(200))],
               expanded: [], trueGolden: 328, falseGolden: 347),
        Fixture(name: "table-plain", userInput: "hello",
               blocks: [.text(table(rows: 12, cols: 4))], expanded: [],
               trueGolden: 408, falseGolden: 427),
        Fixture(name: "table-wide", userInput: "hello",
               blocks: [.text(table(rows: 6, cols: 12))], expanded: [],
               trueGolden: 252, falseGolden: 271),
        Fixture(name: "table-single-row", userInput: "hello",
               blocks: [.text(table(rows: 1, cols: 3))], expanded: [],
               trueGolden: 122, falseGolden: 141),
        Fixture(name: "table-with-prose-around", userInput: "hello",
               blocks: [.text("Intro paragraph.\n\n" + table(rows: 5, cols: 3)
                              + "\n\nTrailing paragraph.")],
               expanded: [], trueGolden: 274, falseGolden: 293),
        Fixture(name: "tool-call", userInput: "run it",
               blocks: [.toolCall(ToolCallData(toolName: "Bash",
                                               inputSummary: "git diff --stat -- macOS/",
                                               inputFull: "{}"))],
               expanded: [], trueGolden: 99, falseGolden: 118),
        Fixture(name: "tool-result-collapsed", userInput: "run it",
               blocks: [.toolResult(ToolResultData(content: text(4_000), isError: false))],
               expanded: [], trueGolden: 95, falseGolden: 114),
        Fixture(name: "tool-result-expanded", userInput: "run it",
               blocks: [.toolResult(ToolResultData(content: text(4_000), isError: false))],
               expanded: [0], trueGolden: 973, falseGolden: 156),
        Fixture(name: "tool-result-error-expanded", userInput: "run it",
               blocks: [.toolResult(ToolResultData(content: text(2_000), isError: true))],
               expanded: [], trueGolden: 536, falseGolden: 156),
        Fixture(name: "result-summary", userInput: "run it",
               blocks: [.resultSummary(ResultSummaryData(durationMs: 1234, costUSD: 0.0217, isError: false))],
               expanded: [], trueGolden: 79, falseGolden: 98),
        Fixture(name: "error-message", userInput: "run it",
               blocks: [.errorMessage("fatal: not a git repository (or any of the parent directories): .git")],
               expanded: [], trueGolden: 101, falseGolden: 120),
        Fixture(name: "ask-question", userInput: "pick one",
               blocks: [.askQuestion(AskQuestionData(
                   question: "Which branch should this land on?",
                   header: "Branch",
                   options: [
                       .init(label: "main", description: "trunk"),
                       .init(label: "release/1.4", description: "the cut"),
                       .init(label: "leave it", description: "do nothing", recommended: true),
                   ],
                   multiSelect: false))],
               expanded: [], trueGolden: 232, falseGolden: 251),
        Fixture(name: "mixed-agentic", userInput: "do the thing",
               blocks: [
                   .toolCall(ToolCallData(toolName: "Read", inputSummary: "ReplView.swift", inputFull: "{}")),
                   .toolResult(ToolResultData(content: text(1_500), isError: false)),
                   .text("## Findings\n\n- " + text(400)),
                   .text(table(rows: 8, cols: 5)),
                   .errorMessage("warning: one file could not be read"),
                   .resultSummary(ResultSummaryData(durationMs: 9_876, costUSD: 0.1, isError: false)),
               ], expanded: [], trueGolden: 554, falseGolden: 573),
        Fixture(name: "long-user-input", userInput: text(600),
               blocks: [.text(text(200))], expanded: [],
               trueGolden: 178, falseGolden: 197),
        Fixture(name: "empty-blocks", userInput: "just a question",
               blocks: [], expanded: [],
               trueGolden: 66, falseGolden: 79),
        Fixture(name: "confirm-reply", userInput: "(This answers your question: main)",
               blocks: [.text("Landing on main, then.")], expanded: [],
               trueGolden: 42, falseGolden: 61),
    ]

    private func buildTurn(_ f: Fixture) -> ChatTurn {
        ChatTurn(userInput: f.userInput, timestamp: Date(), blocks: f.blocks, isComplete: true)
    }

    func testRenderedHeightMatchesGoldensWithContentAvailable() {
        for f in Self.fixtures {
            let turn = buildTurn(f)
            let interaction = TurnInteractionState(expandedBlocks: Set(f.expanded))
            let view = ChatTurnView(turn: turn, contentAvailable: true, interaction: interaction)
            let height = measuredHeight(view)
            XCTAssertEqual(height, f.trueGolden, accuracy: 1.0,
                           "\(f.name) (contentAvailable: true): expected \(f.trueGolden) pt, got \(height) pt")
        }
    }

    func testRenderedHeightMatchesGoldensWithContentUnavailable() {
        for f in Self.fixtures {
            let turn = buildTurn(f)
            let interaction = TurnInteractionState(expandedBlocks: Set(f.expanded))
            let view = ChatTurnView(turn: turn, contentAvailable: false, interaction: interaction)
            let height = measuredHeight(view)
            XCTAssertEqual(height, f.falseGolden, accuracy: 1.0,
                           "\(f.name) (contentAvailable: false): expected \(f.falseGolden) pt, got \(height) pt")
        }
    }

    func testMarkerTurnViewsAreAFixedFortyThreePoints() {
        for marker in [ChatTurn.Marker.gap, .historyUnavailable] {
            let view = MarkerTurnView(marker: marker)
            XCTAssertEqual(measuredHeight(view), 43, accuracy: 1.0,
                           "\(marker) marker height regressed from its fixed golden")
        }
    }

    // MARK: - 4. The turn-height composition identity

    /// Builds the same block view `ChatTurnView.makeBlockView` would, detached
    /// — used only to get an independent, standalone height to compare the
    /// turn's composed total against.
    private func freshBlockView(_ block: TurnBlock, expanded: Bool) -> NSView {
        switch block {
        case .text(let t):          return TextBlockView(text: t)
        case .toolCall(let d):      return ToolCallView(data: d)
        case .toolResult(let d):    return ToolResultView(data: d, contentAvailable: true, startExpanded: expanded)
        case .resultSummary(let d): return ResultChipView(data: d)
        case .errorMessage(let m):  return ErrorBlockView(message: m)
        case .askQuestion(let d):   return AskQuestionView(data: d, answeredOptionIndex: nil)
        }
    }

    /// Independent of the golden numbers above, and so stable across a font or
    /// padding tweak that would legitimately move every golden: the turn's
    /// total height must equal chrome (12 top + 14 bottom) plus the bubble
    /// (its own height plus the 8 pt gap, when there is one) plus every
    /// block's own height plus `blockSpacing` between them. This is what says
    /// `TurnHeightEstimator`'s `turnChrome` / `blockSpacing` /
    /// `blocksWidthFraction` / `bubbleWidthFraction` constants still describe
    /// what `ChatTurnView` actually renders, rather than having drifted.
    func testIslandHeightEqualsChromePlusBubblePlusBlockHeights() throws {
        let paneWidth: CGFloat = 900
        let names = ["plain-text", "tool-result-expanded", "mixed-agentic",
                     "empty-blocks", "confirm-reply"]

        for name in names {
            let f = try XCTUnwrap(Self.fixtures.first { $0.name == name },
                                  "fixture \(name) must exist")
            let turn = buildTurn(f)
            let interaction = TurnInteractionState(expandedBlocks: Set(f.expanded))
            let view = ChatTurnView(turn: turn, contentAvailable: true, interaction: interaction)
            let actual = measuredHeight(view, paneWidth: paneWidth)

            let hasBubble = !f.userInput.contains("(This answers your question:")
            var expected: CGFloat = 12
            if hasBubble {
                let bubbleHeight = ChatTurnView.measureIsland(
                    UserBubbleView(text: f.userInput),
                    width: ChatTurnView.bubbleWidth(paneWidth: paneWidth))
                expected += bubbleHeight + 8
            }
            let blockHeights = f.blocks.enumerated().map { i, block in
                ChatTurnView.measureIsland(
                    freshBlockView(block, expanded: f.expanded.contains(i)),
                    width: ChatTurnView.blockWidth(paneWidth: paneWidth))
            }
            expected += blockHeights.reduce(0, +)
            expected += TurnHeightEstimator.blockSpacing * CGFloat(max(0, blockHeights.count - 1))
            expected += 14

            XCTAssertEqual(actual, expected, accuracy: 0.5,
                           "\(f.name): islandHeight() (\(actual)) must equal chrome + bubble + " +
                           "Σblocks + spacing (\(expected))")
        }
    }

    // MARK: - 5. Incremental streaming yields the same height as building at once

    /// The property that makes streaming's incremental measurement safe:
    /// growing a turn block by block via `update(turn:)`, re-measuring after
    /// each append the way `ReplView` does while a turn streams, must land on
    /// exactly the height of building the finished turn in one shot. Distinct
    /// content per block index (rather than N copies of the same block) is
    /// what would make a bug that reused a stale cached height for an earlier
    /// block, or mis-summed spacing across appends, visible instead of
    /// accidentally uniform.
    func testIncrementalStreamingYieldsSameHeightAsBuildingAtOnce() {
        for n in [1, 2, 5, 17, 40, 120] {
            let blocks = (0..<n).map { TurnBlock.text(Self.text(120 + $0 * 7)) }
            var turn = ChatTurn(userInput: "streaming", timestamp: Date(), blocks: [], isComplete: false)
            let streamed = ChatTurnView(turn: turn, contentAvailable: true, interaction: TurnInteractionState())

            var heights: [CGFloat] = []
            for block in blocks {
                turn.blocks.append(block)
                streamed.update(turn: turn)
                heights.append(measuredHeight(streamed))
            }

            turn.isComplete = true
            let oneShot = ChatTurnView(turn: turn, contentAvailable: true, interaction: TurnInteractionState())
            let oneShotHeight = measuredHeight(oneShot)
            let streamedFinalHeight = heights[heights.count - 1]

            XCTAssertEqual(streamedFinalHeight, oneShotHeight, accuracy: 0.001,
                           "n=\(n): streamed final height (\(streamedFinalHeight)) " +
                           "must exactly equal a one-shot build (\(oneShotHeight))")

            for i in 1..<heights.count {
                XCTAssertGreaterThanOrEqual(heights[i], heights[i - 1],
                                            "n=\(n): height decreased from \(heights[i - 1]) to " +
                                            "\(heights[i]) after appending block \(i)")
            }
        }
    }

    // MARK: - 6. Expanding a tool result changes exactly that block's contribution

    /// Drives expansion through the real UI path — the disclosure button's
    /// `performClick`, exactly the mechanism `ToolResultViewTests` in
    /// `TurnInteractionTests.swift` uses — so this exercises the actual wiring
    /// `ChatTurnView.makeBlockView` installs in production:
    /// `ToolResultView.onExpansionChange` → `remeasureColumnView` →
    /// `invalidateIntrinsicContentSize`. Only the expanded block's own height
    /// should move; every other block's contribution — verified by rebuilding
    /// the turn fresh with that block pre-expanded — must be unaffected.
    func testExpandingOneToolResultChangesOnlyThatBlocksContribution() throws {
        let toolResultContent = Self.text(3_000)
        let blocks: [TurnBlock] = [
            .text(Self.text(300)),
            .toolResult(ToolResultData(content: toolResultContent, isError: false)),
            .text(Self.text(200)),
        ]
        let expandIndex = 1
        let turn = ChatTurn(userInput: "run it", timestamp: Date(), blocks: blocks, isComplete: true)
        let view = ChatTurnView(turn: turn, contentAvailable: true, interaction: TurnInteractionState())
        let before = measuredHeight(view)

        let toolResultView = try XCTUnwrap(firstDescendant(of: ToolResultView.self, in: view),
                                          "the turn must render a ToolResultView for its .toolResult block")
        let button = try XCTUnwrap(firstDescendant(of: NSButton.self, in: toolResultView),
                                  "ToolResultView must expose its disclosure as an NSButton")
        button.performClick(nil)

        let after = measuredHeight(view)

        let width = ChatTurnView.blockWidth(paneWidth: 900)
        let collapsedStandalone = ChatTurnView.measureIsland(
            ToolResultView(data: ToolResultData(content: toolResultContent, isError: false),
                          contentAvailable: true, startExpanded: false),
            width: width)
        let expandedStandalone = ChatTurnView.measureIsland(
            ToolResultView(data: ToolResultData(content: toolResultContent, isError: false),
                          contentAvailable: true, startExpanded: true),
            width: width)
        let delta = expandedStandalone - collapsedStandalone

        XCTAssertEqual(after - before, delta, accuracy: 1.0,
                       "expanding the tool result must change the turn's total height by exactly " +
                       "that one block's own collapsed-to-expanded delta")

        let rebuilt = ChatTurnView(turn: turn, contentAvailable: true,
                                  interaction: TurnInteractionState(expandedBlocks: [expandIndex]))
        let rebuiltHeight = measuredHeight(rebuilt)

        XCTAssertEqual(after, rebuiltHeight, accuracy: 1.0,
                       "every block other than the expanded one must contribute the same height as " +
                       "a turn built fresh with that one block already expanded")
    }

    // MARK: - 7. A pane width change re-measures everything

    /// A completed turn's measured height is cached forever once virtualized
    /// (see `TurnListVirtualizerTests`), so a stale height surviving a resize
    /// would never self-correct. `setIslandWidth` is the one call site
    /// responsible for invalidating that cache; this pins that it actually
    /// does — narrowing changes the height (more wrapping), and returning to
    /// the original width reproduces the *exact* original height rather than
    /// something merely close to it.
    func testPaneWidthChangeReMeasuresAndReturningToTheOriginalWidthReproducesTheOriginalHeight() {
        let turn = ChatTurn(userInput: Self.text(200),
                            timestamp: Date(),
                            blocks: [.text(Self.text(6_000))],
                            isComplete: true)
        let view = ChatTurnView(turn: turn, contentAvailable: true, interaction: TurnInteractionState())

        let wide900 = measuredHeight(view, paneWidth: 900)
        let narrow600 = measuredHeight(view, paneWidth: 600)
        let wideAgain900 = measuredHeight(view, paneWidth: 900)

        XCTAssertEqual(wideAgain900, wide900, accuracy: 0.001,
                       "returning to the original width must reproduce the exact original height, " +
                       "not a stale one left over from the narrower measurement")
        XCTAssertGreaterThan(abs(narrow600 - wide900), 1.0,
                             "narrowing the pane must actually re-wrap the prose block and change its height")
    }
}
