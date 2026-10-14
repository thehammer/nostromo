import XCTest
import NostromoKit

/// The fold rule over the TF0 benchmark session: the PRD's headline claim, measured as row
/// counts (never wall-clock).
final class BenchmarkFoldingTests: XCTestCase {

    private struct FoldedTurn {
        var blocks: [FoldBlock]
        var outcome: FoldOutcome
        var items: [ToolFoldPlanner.Item]
        var wireBlockCount: Int
        var groups: [ToolGroup] {
            items.compactMap { if case .group(let g) = $0 { return g } else { return nil } }
        }
    }

    /// Decoding and planning the whole session is slow in a debug build, so each variant is done once.
    nonisolated(unsafe) private static var cache: [Bool: [FoldedTurn]] = [:]

    private func session(emptyResults: Bool = false) throws -> [FoldedTurn] {
        if let cached = Self.cache[emptyResults] { return cached }
        let data = BenchmarkTranscript.sessionTurnsJSON(emptyResults: emptyResults)
        let turns = try JSONDecoder().decode([DaemonTurn].self, from: data)
        let folded = turns.enumerated().map { index, turn -> FoldedTurn in
            let blocks = FoldBlock.blocks(from: turn.blocks)
            let outcome = FoldOutcome.of(turn)
            return FoldedTurn(blocks: blocks, outcome: outcome,
                              items: ToolFoldPlanner.plan(blocks: blocks, outcome: outcome, turnKey: "t\(index)"),
                              wireBlockCount: turn.blocks.count)
        }
        Self.cache[emptyResults] = folded
        return folded
    }

    // MARK: The headline

    func testFoldingCutsTheRowsOfTheSessionByAtLeastSixtyPercent() throws {
        let turns = try session()

        let today = turns.reduce(0) { $0 + $1.wireBlockCount }
        let folded = turns.reduce(0) { $0 + $1.items.count }
        print("TF2 benchmark rows: today \(today), folded \(folded) (\(String(format: "%.1f", Double(folded) / Double(today) * 100)) %)")

        XCTAssertGreaterThanOrEqual(turns.count, 200)
        XCTAssertLessThanOrEqual(Double(folded), Double(today) * 0.4, "folded \(folded) of today's \(today) rows")
    }

    func testEveryTopLevelNonWhitespaceProseBlockIsStillAVisibleItem() throws {
        var visibleProse = 0
        for turn in try session() {
            for item in turn.items {
                guard case .block(let i) = item, case .prose(let nonEmpty, let parent) = turn.blocks[i] else { continue }
                XCTAssertTrue(nonEmpty)
                XCTAssertNil(parent)
                visibleProse += 1
            }
        }

        XCTAssertEqual(visibleProse, BenchmarkTranscript.summary.proseBlockCount)
    }

    func testNothingTheUserMustSeeIsFolded() throws {
        // Ask cards, error messages and result chips are always their own item.
        for turn in try session() {
            var itemBlocks = Set<Int>()
            for case .block(let i) in turn.items { itemBlocks.insert(i) }
            for (i, block) in turn.blocks.enumerated() {
                if case .boundary = block { XCTAssertTrue(itemBlocks.contains(i), "boundary block \(i) was folded") }
            }
        }
    }

    // MARK: Groups

    func testGroupSizesMatchTheFixturesHistogramIncludingOneTwoTenAndSixty() throws {
        var histogram: [Int: Int] = [:]
        for turn in try session() { for g in turn.groups { histogram[g.callCount, default: 0] += 1 } }

        XCTAssertEqual(histogram, BenchmarkTranscript.summary.groupSizeHistogram)
        for size in [1, 2, 10, 60] { XCTAssertGreaterThan(histogram[size] ?? 0, 0, "a group of \(size)") }
    }

    func testTheNumberOfTopLevelCallsIsTheFixturesCallCount() throws {
        let calls = try session().reduce(0) { $0 + $1.groups.reduce(0) { $0 + $1.callCount } }

        XCTAssertEqual(calls, BenchmarkTranscript.summary.callCount)
    }

    func testEveryGroupOfSixtyHasAFailureAndASummaryThatEndsInMoreWhenLong() throws {
        var checked = 0
        for turn in try session() {
            for g in turn.groups where g.callCount == 60 {
                checked += 1
                XCTAssertGreaterThanOrEqual(g.failedCount, 1)
                let summary = try XCTUnwrap(ToolGroupSummary.summary(for: g))
                XCTAssertTrue(summary.first?.isUppercase == true, summary)
                if summary.components(separatedBy: ", ").count > 3 { XCTAssertTrue(summary.hasSuffix("more"), summary) }
                XCTAssertFalse(summary.contains(" 0 "), summary)
            }
        }
        XCTAssertGreaterThan(checked, 0)
    }

    func testEveryGroupOfOneHasNoSummaryAndEveryLargerGroupHasOne() throws {
        for turn in try session() {
            for g in turn.groups {
                if g.callCount == 1 {
                    XCTAssertNil(ToolGroupSummary.summary(for: g))
                } else {
                    let summary = ToolGroupSummary.summary(for: g)
                    XCTAssertNotNil(summary)
                    XCTAssertFalse(summary?.contains(" 0 ") ?? false, summary ?? "")
                }
            }
        }
    }

    func testEverySettledGroupHasATimeWhenQuietSuccessesCarryTheirFinishTime() throws {
        for turn in try session(emptyResults: true) {
            for g in turn.groups where g.state == .settled {
                XCTAssertNotNil(g.startedAt)
                XCTAssertNotNil(ToolGroupSummary.durationText(for: g), "group \(g.key) has no time")
            }
        }
    }

    func testAGroupWhoseQuietCallNeverReportedItsEndHasNoTimeRatherThanAGuess() throws {
        // Turn 50's last call is an image-only Read whose empty result today's daemon drops.
        let group = try XCTUnwrap(try session()[50].groups.first { $0.calls.contains { $0.name == "Read" && $0.target?.hasSuffix(".png") == true } })

        XCTAssertNil(group.endedAt)
        XCTAssertNil(ToolGroupSummary.durationText(for: group))
        XCTAssertEqual(group.state, .settled)
    }

    func testSubagentCallsAreNeverCountedAsTopLevelCallsOfAGroup() throws {
        var agentGroups = 0
        for turn in try session() {
            for g in turn.groups where !g.subagentBlocks.isEmpty {
                agentGroups += 1
                for (agentIndex, inner) in g.subagentBlocks {
                    XCTAssertTrue(g.callIndices.contains(agentIndex))
                    XCTAssertTrue(inner.allSatisfy { !g.memberIndices.contains($0) })
                    XCTAssertEqual(inner.count, 7, "three calls, three results and one prose per Agent call")
                }
            }
        }
        XCTAssertGreaterThan(agentGroups, 0)
    }

    // MARK: Stuck and interrupted turns

    func testTheStuckTurnOpensItsLastGroup() throws {
        let turns = try session()
        let stuck = turns[210]

        XCTAssertEqual(stuck.outcome, .completedError)
        XCTAssertEqual(stuck.groups.last?.isStuck, true)
        XCTAssertGreaterThanOrEqual(stuck.groups.last?.failedCount ?? 0, 1)
        XCTAssertEqual(stuck.groups.dropLast().filter(\.isStuck).count, 0)
    }

    func testOnlyTheStuckTurnHasAStuckGroup() throws {
        let stuckGroups = try session().enumerated().flatMap { index, turn in turn.groups.filter(\.isStuck).map { _ in index } }

        XCTAssertEqual(stuckGroups, [210])
    }

    func testTheInterruptedTurnsLastGroupIsStoppedAndNotStuck() throws {
        let interrupted = try session()[211]

        XCTAssertEqual(interrupted.outcome, .interrupted)
        XCTAssertEqual(interrupted.groups.last?.state, .stopped)
        XCTAssertEqual(interrupted.groups.last?.isStuck, false)
        XCTAssertEqual(interrupted.groups.last?.callCount, 4)
    }

    // MARK: Empty successful results

    func testEmptyResultsFoldIntoTheirCallsAndLeaveTheGroupsUnchanged() throws {
        let with = try session(emptyResults: true)
        let without = try session(emptyResults: false)

        var hidden = 0
        for turn in with {
            hidden += turn.blocks.filter { $0 == .hidden }.count
            XCTAssertEqual(turn.blocks.count, turn.wireBlockCount)
        }
        XCTAssertGreaterThan(hidden, 0, "the emptyResults variant must contain quiet successes")

        var histogram: [Int: Int] = [:]
        for turn in with { for g in turn.groups { histogram[g.callCount, default: 0] += 1 } }
        XCTAssertEqual(histogram, BenchmarkTranscript.summary.groupSizeHistogram)
        XCTAssertEqual(with.map { $0.groups.map(\.callCount) }, without.map { $0.groups.map(\.callCount) })
    }

    func testAnEmptySuccessMarksItsCallFinishedAtTheMomentTheResultArrived() throws {
        let data = BenchmarkTranscript.sessionTurnsJSON(emptyResults: true)
        let turns = try JSONDecoder().decode([DaemonTurn].self, from: data)
        var checked = 0

        for turn in turns {
            let folded = FoldBlock.blocks(from: turn.blocks)
            var callIndexById: [String: Int] = [:]
            for (i, block) in turn.blocks.enumerated() {
                switch block {
                case .toolCall(_, _, _, let meta):
                    if let id = meta.toolUseId { callIndexById[id] = i }
                case .toolResult(let content, let isError, let meta) where content.isEmpty && !isError:
                    XCTAssertEqual(folded[i], .hidden)
                    guard let id = meta.toolUseId, let callIndex = callIndexById[id],
                          case .toolCall(let call) = folded[callIndex] else { XCTFail("no call for quiet result \(i)"); continue }
                    XCTAssertNotNil(meta.ts)
                    XCTAssertEqual(call.finishedAt, meta.ts)
                    checked += 1
                default: break
                }
            }
        }
        XCTAssertGreaterThan(checked, 0)
    }
}
