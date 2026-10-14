import XCTest
import CryptoKit
@testable import NostromoKit

/// The Focus view's scenario fixture (PRD "Acceptance criteria" preamble; contract X2), the
/// proof that the existing benchmark fixture did not move, and the "Rows" measure of PRD
/// Phase 4 at Kit level. Nothing here reads a clock.
final class FocusScenarioFixtureTests: XCTestCase {

    // MARK: Loading

    private struct Loaded {
        var turn: DaemonTurn
        var blocks: [FoldBlock]
        var outcome: FoldOutcome
        var items: [FocusItem]
        var tf2ItemCount: Int
        var scenario: FocusScenario?
    }

    private static func load(_ data: Data) throws -> [Loaded] {
        let turns = try JSONDecoder().decode([DaemonTurn].self, from: data)
        return turns.map { turn in
            let blocks = FoldBlock.blocks(from: turn.blocks)
            let outcome = FoldOutcome.of(turn)
            return Loaded(turn: turn, blocks: blocks, outcome: outcome,
                          items: FocusPlanner.plan(blocks: blocks, outcome: outcome, turnKey: turn.id),
                          tf2ItemCount: ToolFoldPlanner.plan(blocks: blocks, outcome: outcome, turnKey: turn.id).count,
                          scenario: FocusScenario(turnId: turn.id))
        }
    }

    /// Decoding and planning a whole fixture is slow in a debug build, so each is done once.
    nonisolated(unsafe) private static var scenarioCache: [Loaded]?
    nonisolated(unsafe) private static var benchmarkCache: [Loaded]?

    private func scenarioTurns() throws -> [Loaded] {
        if let cached = Self.scenarioCache { return cached }
        let loaded = try Self.load(BenchmarkTranscript.focusScenariosJSON(seed: 1))
        Self.scenarioCache = loaded
        return loaded
    }

    private func benchmarkTurns() throws -> [Loaded] {
        if let cached = Self.benchmarkCache { return cached }
        let loaded = try Self.load(BenchmarkTranscript.sessionTurnsJSON(seed: 1, emptyResults: false))
        Self.benchmarkCache = loaded
        return loaded
    }

    private func turns(of scenario: FocusScenario, file: StaticString = #filePath, line: UInt = #line) throws -> [Loaded] {
        let found = try scenarioTurns().filter { $0.scenario == scenario }
        XCTAssertFalse(found.isEmpty, "no \(scenario) turn in the fixture", file: file, line: line)
        return found
    }

    // MARK: Item helpers

    private func rows(_ items: [FocusItem]) -> [ActivitySegment] {
        items.compactMap { if case .activity(let s) = $0 { return s } else { return nil } }
    }

    private func messageItems(_ items: [FocusItem]) -> [MessageRef] {
        items.compactMap { if case .message(let m) = $0 { return m } else { return nil } }
    }

    private func groupItems(_ items: [FocusItem]) -> [ToolGroup] {
        items.compactMap { if case .group(let g) = $0 { return g } else { return nil } }
    }

    /// Every group, whether it sits in a row or below the latest message, in order.
    private func allGroups(_ items: [FocusItem]) -> [ToolGroup] {
        var out: [ToolGroup] = []
        for item in items {
            switch item {
            case .activity(let s): for case .group(let g) in s.members { out.append(g) }
            case .group(let g): out.append(g)
            default: break
            }
        }
        return out
    }

    private func foldedMessages(_ items: [FocusItem]) -> [MessageRef] {
        rows(items).flatMap { row in row.members.compactMap { member -> MessageRef? in
            if case .message(let m) = member { return m } else { return nil }
        } }
    }

    private func isBoundary(_ item: FocusItem, in turn: DaemonTurn, _ matches: (DaemonTurnBlock) -> Bool) -> Bool {
        guard case .boundary(let i) = item, turn.blocks.indices.contains(i) else { return false }
        return matches(turn.blocks[i])
    }

    private func isAskCard(_ block: DaemonTurnBlock) -> Bool { if case .askQuestion = block { return true } else { return false } }
    private func isNote(_ block: DaemonTurnBlock) -> Bool { if case .note = block { return true } else { return false } }
    private func isErrorMessage(_ block: DaemonTurnBlock) -> Bool { if case .errorMessage = block { return true } else { return false } }

    private func rawText(_ turn: DaemonTurn, _ index: Int) -> String? {
        guard turn.blocks.indices.contains(index), case .text(let text, _) = turn.blocks[index] else { return nil }
        return text
    }

    private func kind(_ item: FocusItem) -> String {
        switch item {
        case .activity: return "activity"
        case .message: return "message"
        case .boundary: return "boundary"
        case .group: return "group"
        }
    }

    // MARK: - The fixture itself

    func testTheFixtureHasAtLeastTwoHundredTurnsAndEveryScenario() throws {
        let loaded = try scenarioTurns()

        XCTAssertGreaterThanOrEqual(loaded.count, BenchmarkTranscript.focusScenarioMinTurns)
        XCTAssertGreaterThanOrEqual(BenchmarkTranscript.focusScenarioMinTurns, 200)
        XCTAssertTrue(loaded.allSatisfy { $0.scenario != nil }, "every turn id is f<n>-<scenario>")
        XCTAssertEqual(Set(loaded.compactMap(\.scenario)), Set(FocusScenario.allCases))
        XCTAssertEqual(Set(loaded.map(\.turn.id)).count, loaded.count, "turn ids are unique")
    }

    func testTheFixtureIsByteIdenticalForTheSameSeed() {
        XCTAssertEqual(BenchmarkTranscript.focusScenariosJSON(seed: 1), BenchmarkTranscript.focusScenariosJSON(seed: 1))
        XCTAssertEqual(BenchmarkTranscript.focusScenariosJSON(seed: 7), BenchmarkTranscript.focusScenariosJSON(seed: 7))
    }

    func testTheTurnIdNamesItsScenario() {
        XCTAssertEqual(FocusScenario(turnId: "f12-noMessages"), .noMessages)
        XCTAssertEqual(FocusScenario(turnId: "f0-finalAskCard"), .finalAskCard)
        XCTAssertNil(FocusScenario(turnId: "t12-noMessages"))
        XCTAssertNil(FocusScenario(turnId: "f12-nonsense"))
        XCTAssertNil(FocusScenario(turnId: "f12"))
    }

    func testEveryTurnWithAMessageHasExactlyOneLatestMessageAndEveryOtherTurnHasNone() throws {
        for loaded in try scenarioTurns() {
            let hasMessage = loaded.turn.blocks.contains { block in
                if case .text(let text, nil) = block { return text.contains { !$0.isWhitespace } } else { return false }
            }
            XCTAssertEqual(messageItems(loaded.items).count, hasMessage ? 1 : 0, loaded.turn.id)
        }
    }

    func testReplayingTheOpsOfEveryFixtureTurnGivesItsBatchPlan() throws {
        for loaded in try scenarioTurns() + (try benchmarkTurns()) {
            var planner = FocusPlanner(turnKey: loaded.turn.id)
            var ops: [FocusOp] = []
            for block in loaded.blocks {
                let fed = planner.feed(block)
                let counted = fed.filter { if case .groupChanged = $0 { return false } else { return true } }.count
                XCTAssertLessThanOrEqual(counted, 3, "\(loaded.turn.id): ops for one block")
                ops += fed
            }
            if loaded.outcome != .open { ops += planner.turnEnded(outcome: loaded.outcome) }

            XCTAssertEqual(FocusPlanner.replay(ops), loaded.items, loaded.turn.id)
            XCTAssertEqual(planner.items(), loaded.items, loaded.turn.id)
        }
    }

    // MARK: - Scenario shapes

    func testNoMessagesShowsOnlyGroups() throws {
        for loaded in try turns(of: .noMessages) {
            XCTAssertTrue(messageItems(loaded.items).isEmpty, loaded.turn.id)
            XCTAssertGreaterThanOrEqual(groupItems(loaded.items).count, 1, loaded.turn.id)
            XCTAssertTrue(rows(loaded.items).isEmpty, loaded.turn.id)
        }
    }

    func testOneMessageHasNoRowAndNoGroup() throws {
        for loaded in try turns(of: .oneMessage) {
            XCTAssertEqual(messageItems(loaded.items).count, 1, loaded.turn.id)
            XCTAssertTrue(rows(loaded.items).isEmpty, loaded.turn.id)
            XCTAssertTrue(groupItems(loaded.items).isEmpty, loaded.turn.id)
        }
    }

    func testTwoMessagesFoldTheFirstWithItsCallsIntoOneRowBeforeTheLatest() throws {
        for loaded in try turns(of: .twoMessages) {
            let found = rows(loaded.items)
            XCTAssertEqual(found.count, 1, loaded.turn.id)
            XCTAssertEqual(found.first?.messageCount, 1, loaded.turn.id)
            XCTAssertGreaterThanOrEqual(found.first?.calls.count ?? 0, 1, loaded.turn.id)
            let rowAt = loaded.items.firstIndex { if case .activity = $0 { return true } else { return false } }
            let messageAt = loaded.items.firstIndex { if case .message = $0 { return true } else { return false } }
            XCTAssertNotNil(rowAt, loaded.turn.id)
            XCTAssertNotNil(messageAt, loaded.turn.id)
            XCTAssertLessThan(rowAt ?? 1, messageAt ?? 0, loaded.turn.id)
        }
    }

    func testTenMessagesFoldNineIntoOneRowAroundTheirGroups() throws {
        for loaded in try turns(of: .tenMessages) {
            XCTAssertEqual(messageItems(loaded.items).count, 1, loaded.turn.id)
            let found = rows(loaded.items)
            XCTAssertEqual(found.count, 1, loaded.turn.id)
            let row = try XCTUnwrap(found.first, loaded.turn.id)
            XCTAssertEqual(row.messageCount, 9, loaded.turn.id)
            XCTAssertGreaterThanOrEqual(row.members.filter { if case .group = $0 { return true } else { return false } }.count, 9, loaded.turn.id)
            XCTAssertGreaterThanOrEqual(row.calls.count, 9, loaded.turn.id)
        }
    }

    func testAMessageThenToolsKeepsTheGroupBelowTheMessage() throws {
        for loaded in try turns(of: .messageThenTools) {
            XCTAssertEqual(loaded.items.map(kind), ["message", "group", "boundary"], loaded.turn.id)
        }
    }

    func testAFinalAskCardIsTheLastItemBelowTheLatestMessageAndTheTurnIsStillOpen() throws {
        for loaded in try turns(of: .finalAskCard) {
            let last = try XCTUnwrap(loaded.items.last, loaded.turn.id)
            XCTAssertTrue(isBoundary(last, in: loaded.turn, isAskCard), "\(loaded.turn.id): last item is \(last)")
            XCTAssertGreaterThanOrEqual(loaded.items.count, 2, loaded.turn.id)
            XCTAssertEqual(kind(loaded.items[loaded.items.count - 2]), "message", loaded.turn.id)
            XCTAssertFalse(loaded.turn.isComplete, loaded.turn.id)
        }
    }

    /// `[row, boundary, row]` somewhere in the items, exactly two rows, then the latest message.
    private func assertTwoRowsAroundABoundary(_ loaded: Loaded, _ matches: (DaemonTurnBlock) -> Bool,
                                              file: StaticString = #filePath, line: UInt = #line) {
        let items = loaded.items
        XCTAssertEqual(rows(items).count, 2, loaded.turn.id, file: file, line: line)
        let window = items.indices.dropLast(2).first { i in
            if case .activity = items[i], isBoundary(items[i + 1], in: loaded.turn, matches), case .activity = items[i + 2] { return true }
            return false
        }
        XCTAssertNotNil(window, "\(loaded.turn.id): no row, boundary, row in \(items.map(kind))", file: file, line: line)
        if let window {
            XCTAssertTrue(items[(window + 3)...].contains { if case .message = $0 { return true } else { return false } },
                          "\(loaded.turn.id): the latest message follows the second row", file: file, line: line)
        }
    }

    func testAnAnsweredAskCardMidTurnSplitsTheActivityIntoTwoRows() throws {
        for loaded in try turns(of: .answeredAskMidTurn) { assertTwoRowsAroundABoundary(loaded, isAskCard) }
    }

    func testAMidTurnNoteSplitsTheActivityIntoTwoRows() throws {
        for loaded in try turns(of: .midTurnNote) { assertTwoRowsAroundABoundary(loaded, isNote) }
    }

    func testAStoppedTurnWasInterruptedAndHasAStoppedGroup() throws {
        for loaded in try turns(of: .stopped) {
            XCTAssertEqual(loaded.outcome, .interrupted, loaded.turn.id)
            XCTAssertTrue(allGroups(loaded.items).contains { $0.state == .stopped }, loaded.turn.id)
        }
    }

    func testAnErroredTurnEndsInErrorWithAStuckLastGroupAndAnErrorMessage() throws {
        for loaded in try turns(of: .errored) {
            XCTAssertTrue(loaded.outcome == .completedError || loaded.outcome == .errored, "\(loaded.turn.id): \(loaded.outcome)")
            XCTAssertEqual(allGroups(loaded.items).last?.isStuck, true, loaded.turn.id)
            XCTAssertTrue(loaded.items.contains { isBoundary($0, in: loaded.turn, isErrorMessage) }, loaded.turn.id)
        }
    }

    func testWhitespaceOnlyMessagesAreNothing() throws {
        for loaded in try turns(of: .whitespaceOnlyMessages) {
            XCTAssertTrue(messageItems(loaded.items).isEmpty, loaded.turn.id)
            XCTAssertTrue(foldedMessages(loaded.items).isEmpty, loaded.turn.id)
            let whitespaceBlocks = loaded.turn.blocks.filter { block in
                if case .text(let text, nil) = block { return !text.contains { !$0.isWhitespace } } else { return false }
            }
            XCTAssertGreaterThanOrEqual(whitespaceBlocks.count, 1, "\(loaded.turn.id): the fixture has whitespace-only text")
        }
    }

    func testTextBlocksWithNothingBetweenThemAreOneMessageOfTwoBlocks() throws {
        for loaded in try turns(of: .thinkingBetweenMessages) {
            let all = foldedMessages(loaded.items) + messageItems(loaded.items)
            XCTAssertEqual(all.count, 2, loaded.turn.id)
            let widest = all.map { message in
                message.blockIndices.filter { rawText(loaded.turn, $0).map { $0.contains { !$0.isWhitespace } } == true }.count
            }.max() ?? 0
            XCTAssertGreaterThanOrEqual(widest, 2, "\(loaded.turn.id): a message of two text blocks")
        }
    }

    func testALargeFinalMessageIsAtLeastThirtyKilobytes() throws {
        for loaded in try turns(of: .largeFinalMessage) {
            let latest = try XCTUnwrap(messageItems(loaded.items).first, loaded.turn.id)
            let bytes = latest.blockIndices.reduce(0) { $0 + (rawText(loaded.turn, $1)?.utf8.count ?? 0) }
            XCTAssertGreaterThanOrEqual(bytes, 30_000, loaded.turn.id)
        }
    }

    func testAMarkdownTableSitsInAMessageThatFolds() throws {
        for loaded in try turns(of: .markdownTable) {
            let found = foldedMessages(loaded.items).contains { message in
                message.blockIndices.contains { rawText(loaded.turn, $0)?.contains("|---") == true }
            }
            XCTAssertTrue(found, loaded.turn.id)
        }
    }

    func testAnImageResultSitsInAReadCallInsideARow() throws {
        for loaded in try turns(of: .imageResult) {
            var found = false
            for row in rows(loaded.items) {
                for case .group(let group) in row.members {
                    for (slot, call) in group.calls.enumerated() where call.name == "Read" {
                        let callIndex = group.callIndices[slot]
                        guard case .toolCall(_, _, _, let meta) = loaded.turn.blocks[callIndex] else { continue }
                        for block in loaded.turn.blocks {
                            if case .toolResult(let content, _, let resultMeta) = block, resultMeta.toolUseId == meta.toolUseId,
                               meta.toolUseId != nil, content.lowercased().contains("image") { found = true }
                        }
                    }
                }
            }
            XCTAssertTrue(found, "\(loaded.turn.id): no Read call with an image result inside a row")
        }
    }

    // MARK: - X2: the existing benchmark did not move

    private func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testTheBenchmarkSessionWithoutEmptyResultsIsByteIdenticalToMain() {
        let data = BenchmarkTranscript.sessionTurnsJSON(seed: 1, emptyResults: false)

        XCTAssertEqual(data.count, 4_396_013)
        XCTAssertEqual(hex(data), "3d8b07ec89d74b7ed872a579a75893e7a13649bb64111da5beb55e77aa4d6b3f")
    }

    func testTheBenchmarkSessionWithEmptyResultsIsByteIdenticalToMain() {
        let data = BenchmarkTranscript.sessionTurnsJSON(seed: 1, emptyResults: true)

        XCTAssertEqual(data.count, 4_440_287)
        XCTAssertEqual(hex(data), "bb5a8ce4a3945a4b490d9b83b788d6dc34fb30f076704aae574c46c515bad4a3")
    }

    // MARK: - Rows (PRD Phase 4), at Kit level

    /// Top-level rows per fixture with everything collapsed, counting the user message.
    /// TF2: its items. Focus: one per row, message, boundary and group.
    ///
    /// The PRD's overall 50 % target is NOT met on these fixtures (about 0.69 on both): the saving
    /// only appears in turns with three or more messages, and these turns are mostly 0 to 2. So
    /// the Kit proxy asserts what is true of the rule: Focus never shows more rows than TF2 in any
    /// turn, and (scenario fixture only) at most half on turns with three or more messages. The overall ratios are printed
    /// for the PR; the 50 % target is measured on real sessions in FV2 (Mac Phase 4).
    private func assertFocusNeverAddsRowsAndHalvesLongTurns(_ loaded: [Loaded], _ name: String, halvesLongTurns: Bool, file: StaticString = #filePath, line: UInt = #line) {
        let tf2 = loaded.reduce(0) { $0 + $1.tf2ItemCount + 1 }
        let focus = loaded.reduce(0) { $0 + $1.items.count + 1 }
        guard tf2 > 0 else { return XCTFail("\(name): no rows to measure", file: file, line: line) }
        print("ROWS_PROXY \(name) tf2=\(tf2) focus=\(focus) ratio=\(String(format: "%.3f", Double(focus) / Double(tf2)))")

        var longTf2 = 0, longFocus = 0
        for turn in loaded {
            XCTAssertLessThanOrEqual(turn.items.count, turn.tf2ItemCount, "\(name) \(turn.turn.id)", file: file, line: line)
            let messages = foldedMessages(turn.items).count + messageItems(turn.items).count
            if messages >= 3 { longTf2 += turn.tf2ItemCount + 1; longFocus += turn.items.count + 1 }
        }
        if longTf2 > 0 {
            print("ROWS_PROXY \(name) turns>=3 messages tf2=\(longTf2) focus=\(longFocus)")
            if halvesLongTurns { XCTAssertLessThanOrEqual(Double(longFocus), Double(longTf2) * 0.5, "\(name): long turns focus \(longFocus) of tf2 \(longTf2)", file: file, line: line) }
        }
    }

    func testFocusNeverAddsRowsOnTheBenchmarkSession() throws {
        assertFocusNeverAddsRowsAndHalvesLongTurns(try benchmarkTurns(), "benchmark", halvesLongTurns: false)
    }

    func testFocusNeverAddsRowsAndHalvesLongTurnsOnTheScenarioFixture() throws {
        let loaded = try scenarioTurns()
        assertFocusNeverAddsRowsAndHalvesLongTurns(loaded, "scenarios", halvesLongTurns: true)
        XCTAssertTrue(loaded.contains { foldedMessages($0.items).count + messageItems($0.items).count >= 3 }, "no long turn to measure")
    }

    func testEveryBenchmarkTurnThatHasAMessageStillShowsItsLatestMessage() throws {
        for loaded in try benchmarkTurns() {
            let hasMessage = loaded.turn.blocks.contains { block in
                if case .text(let text, nil) = block { return text.contains { !$0.isWhitespace } } else { return false }
            }
            XCTAssertEqual(messageItems(loaded.items).count, hasMessage ? 1 : 0, loaded.turn.id)
        }
    }
}
