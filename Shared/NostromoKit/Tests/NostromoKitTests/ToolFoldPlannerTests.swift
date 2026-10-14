import XCTest
import NostromoKit

/// The grouping rule (PRD "What forms a group"; contract §2.2, §2.4).
///
/// The planner takes ONE turn's blocks. Nothing crosses turns by construction: a consumer
/// plans each turn on its own, and group ids and fallback keys restart per turn.
final class ToolFoldPlannerTests: XCTestCase {

    // MARK: Builders

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    private func call(_ name: String = "Bash", id: String? = nil, parent: String? = nil, target: String? = nil,
                      started: Double? = nil, finished: Double? = nil) -> FoldBlock {
        .toolCall(FoldCall(name: name, toolUseId: id, parentId: parent, target: target,
                           startedAt: started.map(at), finishedAt: finished.map(at)))
    }

    private func result(_ id: String?, parent: String? = nil, error: Bool = false, at seconds: Double? = nil) -> FoldBlock {
        .toolResult(FoldResult(toolUseId: id, parentId: parent, isError: error, at: seconds.map(at)))
    }

    private let prose = FoldBlock.prose(nonEmpty: true)
    private let whitespace = FoldBlock.prose(nonEmpty: false)

    private func plan(_ blocks: [FoldBlock], _ outcome: FoldOutcome = .completedOk,
                      key: String = "T") -> [ToolFoldPlanner.Item] {
        ToolFoldPlanner.plan(blocks: blocks, outcome: outcome, turnKey: key)
    }

    private func groups(_ items: [ToolFoldPlanner.Item]) -> [ToolGroup] {
        items.compactMap { if case .group(let g) = $0 { return g } else { return nil } }
    }

    /// `b<index>` for a block item, `g<id>` for a group item.
    private func shape(_ items: [ToolFoldPlanner.Item]) -> [String] {
        items.map {
            switch $0 {
            case .block(let i): return "b\(i)"
            case .group(let g): return "g\(g.id)"
            }
        }
    }

    private func onlyGroup(_ blocks: [FoldBlock], _ outcome: FoldOutcome = .completedOk,
                           key: String = "T", file: StaticString = #filePath, line: UInt = #line) throws -> ToolGroup {
        let found = groups(plan(blocks, outcome, key: key))
        XCTAssertEqual(found.count, 1, "expected exactly one group", file: file, line: line)
        return try XCTUnwrap(found.first, file: file, line: line)
    }

    // MARK: What forms a group

    func testProseFourCallsProseIsExactlyOneGroupBetweenTheProse() throws {
        var blocks: [FoldBlock] = [prose]
        for n in 1 ... 4 { blocks += [call(id: "c\(n)"), result("c\(n)")] }
        blocks.append(prose)

        let items = plan(blocks)

        XCTAssertEqual(shape(items), ["b0", "g0", "b9"])
        let g = try XCTUnwrap(groups(items).first)
        XCTAssertEqual(g.callCount, 4)
        XCTAssertEqual(g.memberIndices, [1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(g.callIndices, [1, 3, 5, 7])
    }

    func testCallsSeparatedOnlyByHiddenBlocksFormOneGroup() throws {
        let blocks: [FoldBlock] = [call(id: "a"), result("a"), .hidden, call(id: "b"), result("b"), .hidden, .hidden, call(id: "c")]

        let items = plan(blocks)

        XCTAssertEqual(shape(items), ["g0"], "hidden blocks are not items")
        let g = try XCTUnwrap(groups(items).first)
        XCTAssertEqual(g.callCount, 3)
        XCTAssertEqual(g.memberIndices, [0, 1, 3, 4, 7], "hidden blocks are not members")
    }

    func testCallsSeparatedOnlyByWhitespaceProseFormOneGroup() throws {
        let blocks: [FoldBlock] = [call(id: "a"), result("a"), whitespace, call(id: "b"), result("b"), whitespace, call(id: "c"), result("c")]

        let items = plan(blocks)

        XCTAssertEqual(shape(items), ["g0"], "whitespace prose shows as nothing, so it is not an item")
        let g = try XCTUnwrap(groups(items).first)
        XCTAssertEqual(g.callCount, 3)
        XCTAssertEqual(g.memberIndices, [0, 1, 3, 4, 6, 7], "whitespace prose is not a member")
    }

    private func assertSeparates(_ separator: FoldBlock, file: StaticString = #filePath, line: UInt = #line) {
        let blocks: [FoldBlock] = [call(id: "a"), result("a"), separator, call(id: "b"), result("b")]

        let items = plan(blocks)

        XCTAssertEqual(shape(items), ["g0", "b2", "g1"], file: file, line: line)
        let found = groups(items)
        XCTAssertEqual(found.map(\.callCount), [1, 1], file: file, line: line)
        XCTAssertEqual(found.map(\.memberIndices), [[0, 1], [3, 4]], file: file, line: line)
    }

    func testNonEmptyProseSeparatesTwoGroups() { assertSeparates(prose) }
    func testAskQuestionCardSeparatesTwoGroups() { assertSeparates(.boundary(.askQuestion)) }
    func testErrorMessageSeparatesTwoGroups() { assertSeparates(.boundary(.errorMessage)) }
    func testNoteSeparatesTwoGroups() { assertSeparates(.boundary(.note)) }
    func testResultSummarySeparatesTwoGroups() { assertSeparates(.boundary(.resultSummary)) }
    func testAnyOtherBoundarySeparatesTwoGroups() { assertSeparates(.boundary(.other)) }

    func testASingleCallIsAGroupOfOne() throws {
        let g = try onlyGroup([call(id: "only"), result("only")])

        XCTAssertEqual(g.callCount, 1)
        XCTAssertEqual(g.memberIndices, [0, 1])
    }

    func testASingleCallStillWaitingForItsResultIsAGroupOfOne() throws {
        let g = try onlyGroup([prose, call(id: "only")], .open)

        XCTAssertEqual(g.callCount, 1)
        XCTAssertEqual(g.memberIndices, [1])
    }

    func testAnEmptyTurnAndATurnWithoutToolsHaveNoGroups() {
        XCTAssertEqual(plan([]), [])
        XCTAssertEqual(shape(plan([prose, .boundary(.resultSummary)])), ["b0", "b1"])
    }

    func testGroupsOfOneTurnAreNumberedFromZeroAndTheNextTurnStartsOverAtZero() {
        let turnA: [FoldBlock] = [call(id: "a1"), prose, call(id: "a2"), prose, call(id: "a3")]
        let turnB: [FoldBlock] = [prose, call(id: "b1"), result("b1"), .boundary(.askQuestion), call(id: "b2")]

        // The planner takes one turn. A group can only contain blocks the caller handed over.
        let itemsA = plan(turnA, key: "turnA")
        var plannerB = ToolFoldPlanner(turnKey: "turnB")
        for block in turnB { _ = plannerB.feed(block) }

        XCTAssertEqual(groups(itemsA).map(\.id), [0, 1, 2])
        XCTAssertEqual(groups(plannerB.items()).map(\.id), [0, 1])
        XCTAssertEqual(groups(plannerB.items()).map(\.memberIndices), [[1, 2], [4]],
                       "indices are relative to the turn it was given")
        XCTAssertEqual(plannerB.blockCount, turnB.count)
    }

    func testAnOrphanResultWithNoGroupOpenRendersAsItselfAndALaterCallStartsAGroup() throws {
        // Older blocks were shed: the turn starts with the tail of a call we never saw.
        let items = plan([result("shed"), call(id: "a"), result("a")])

        XCTAssertEqual(shape(items), ["b0", "g0"])
        XCTAssertEqual(try XCTUnwrap(groups(items).first).memberIndices, [1, 2])
    }

    // MARK: Subagents

    func testSubagentBlocksAttachToTheirAgentCallAndAreNotGroupMembers() throws {
        let blocks: [FoldBlock] = [
            prose,                                                       // 0
            call("Agent", id: "A"),                                      // 1
            call("Bash", id: "s1", parent: "A"),                         // 2
            result("s1", parent: "A"),                                   // 3
            .prose(nonEmpty: true, parentId: "A"),                       // 4
            result("A"),                                                 // 5
            call("Bash", id: "b1"), result("b1"),                        // 6, 7
            prose,                                                       // 8
        ]

        let items = plan(blocks)

        XCTAssertEqual(shape(items), ["b0", "g0", "b8"], "subagent prose does not end the group")
        let g = try XCTUnwrap(groups(items).first)
        XCTAssertEqual(g.callCount, 2, "the subagent's calls are not calls of the group")
        XCTAssertEqual(g.callIndices, [1, 6])
        XCTAssertEqual(g.calls.map(\.name), ["Agent", "Bash"])
        XCTAssertEqual(g.memberIndices, [1, 5, 6, 7])
        XCTAssertEqual(g.subagentBlocks, [1: [2, 3, 4]])
    }

    func testTaskCallsAlsoHostSubagentBlocks() throws {
        let g = try onlyGroup([call("Task", id: "T1"), call("Read", id: "s", parent: "T1"), result("s", parent: "T1"), result("T1")])

        XCTAssertEqual(g.callCount, 1)
        XCTAssertEqual(g.subagentBlocks, [0: [1, 2]])
        XCTAssertEqual(g.memberIndices, [0, 3])
    }

    func testSubagentBlocksDoNotSplitTheGroupAroundThem() throws {
        let g = try onlyGroup([
            call("Bash", id: "b1"), result("b1"),
            call("Agent", id: "A"),
            call("Read", id: "s1", parent: "A"), result("s1", parent: "A"),
            result("A"),
            call("Bash", id: "b2"), result("b2"),
        ])

        XCTAssertEqual(g.callCount, 3)
        XCTAssertEqual(g.subagentBlocks, [2: [3, 4]])
    }

    func testAnUnknownParentMarkerAttachesToTheMostRecentUnfinishedAgentCall() throws {
        let blocks: [FoldBlock] = [
            call("Agent", id: "A1"),                      // 0
            call("Agent", id: "A2"),                      // 1
            call("Bash", id: "s1", parent: "?"),          // 2  -> most recent unfinished: A2
            result("A2"),                                 // 3  A2 is now finished
            result("s1", parent: "?"),                    // 4  -> A1, the only unfinished left
        ]

        let g = try onlyGroup(blocks, .open)

        XCTAssertEqual(g.callCount, 2)
        XCTAssertEqual(g.subagentBlocks, [1: [2], 0: [4]])
        XCTAssertEqual(g.memberIndices, [0, 1, 3])
    }

    func testAnAgentCallWithFinishedAtIsNotUnfinishedForAttachment() throws {
        let blocks: [FoldBlock] = [
            call("Agent", id: "A1"),                      // 0 unfinished
            call("Agent", id: "A2", finished: 5),         // 1 finishedAt set
            call("Bash", id: "s1", parent: "?"),          // 2 -> A1
        ]

        let g = try onlyGroup(blocks, .open)

        XCTAssertEqual(g.subagentBlocks, [0: [2]])
    }

    func testAParentIdThatMatchesNoAgentCallAttachesToTheMostRecentUnfinishedAgentCall() throws {
        let g = try onlyGroup([call("Agent", id: "A"), call("Bash", id: "s1", parent: "no-such-agent")], .open)

        XCTAssertEqual(g.callCount, 1)
        XCTAssertEqual(g.subagentBlocks, [0: [1]])
    }

    func testSubagentBlocksWithNoAgentCallToAttachToBecomeOrdinaryMembers() throws {
        let blocks: [FoldBlock] = [
            call("Bash", id: "b1"),                       // 0
            call("Read", id: "s1", parent: "A"),          // 1  no Agent/Task call exists
            result("s1", parent: "A"),                    // 2
            result("b1"),                                 // 3
        ]

        let g = try onlyGroup(blocks)

        XCTAssertEqual(g.callCount, 2, "the fallback counts them")
        XCTAssertEqual(g.memberIndices, [0, 1, 2, 3])
        XCTAssertTrue(g.subagentBlocks.isEmpty)
    }

    func testSubagentMarkerWithNoAgentCallAlsoFallsBackToOrdinaryMembers() throws {
        let g = try onlyGroup([call("Bash", id: "b1"), call("Bash", id: "s1", parent: "?"), result("s1", parent: "?")])

        XCTAssertEqual(g.callCount, 2)
        XCTAssertEqual(g.memberIndices, [0, 1, 2])
    }

    func testSubagentProseWithNoAgentCallRendersAsItselfAndEndsTheGroup() {
        let blocks: [FoldBlock] = [call("Bash", id: "b1"), .prose(nonEmpty: true, parentId: "A"), call("Bash", id: "b2")]

        let items = plan(blocks)

        XCTAssertEqual(shape(items), ["g0", "b1", "g1"])
    }

    // MARK: Pairing and completion

    func testACallIsFinishedWhenItsResultArrivesWhateverTheOrder() throws {
        let blocks: [FoldBlock] = [call(id: "a"), call(id: "b"), call(id: "c"), result("b"), result("a")]

        let g = try onlyGroup(blocks, .open)

        XCTAssertEqual(g.callCount, 3)
        XCTAssertEqual(g.finishedCount, 2)
        XCTAssertEqual(g.runningCall, 2, "c is the only unfinished call")
    }

    func testACallWithFinishedAtIsFinishedWithoutAResult() throws {
        let g = try onlyGroup([call(id: "a", finished: 2), call(id: "b")], .open)

        XCTAssertEqual(g.finishedCount, 1)
        XCTAssertEqual(g.runningCall, 1)
    }

    func testTheRunningCallIsTheLastUnfinishedOne() throws {
        let g = try onlyGroup([call(id: "a"), call(id: "b"), call(id: "c"), result("b")], .open)

        XCTAssertEqual(g.finishedCount, 1)
        XCTAssertEqual(g.runningCall, 2)
    }

    func testEveryCallCountsAsFinishedOnceTheTurnHasEnded() throws {
        for outcome in [FoldOutcome.completedOk, .completedError, .errored] {
            let g = try onlyGroup([call(id: "a"), result("a"), call(id: "b")], outcome)
            XCTAssertEqual(g.finishedCount, 2, "\(outcome)")
            XCTAssertNil(g.runningCall, "\(outcome)")
        }
    }

    /// PRD "Interrupted turn (Stop)": calls with no result count as not finished (and not
    /// failed), where the contract's "the turn ended" would finish them.
    func testAStoppedTurnLeavesItsResultlessCallsUnfinished() throws {
        let g = try onlyGroup([call(id: "a"), result("a"), call(id: "b")], .interrupted)
        XCTAssertEqual(g.finishedCount, 1)
        XCTAssertEqual(g.failedCount, 0)
        XCTAssertNil(g.runningCall)
    }

    func testWithoutIdsResultsPairWithCallsPositionally() throws {
        // An older daemon sends no tool_use_id: the n-th result answers the n-th call without one.
        let g = try onlyGroup([call(), call(), call(), result(nil), result(nil)], .open)

        XCTAssertEqual(g.callCount, 3)
        XCTAssertEqual(g.finishedCount, 2)
        XCTAssertEqual(g.runningCall, 2)
        XCTAssertEqual(g.memberIndices, [0, 1, 2, 3, 4])
    }

    func testWithoutIdsAResultAfterEachCallFinishesEveryCall() throws {
        let g = try onlyGroup([call(), result(nil), call(), result(nil)], .open)

        XCTAssertEqual(g.finishedCount, 2)
        XCTAssertNil(g.runningCall)
    }

    func testFailedCountIsTopLevelErrorResultsOnly() throws {
        let blocks: [FoldBlock] = [
            call("Bash", id: "b1"), result("b1", error: true),
            call("Agent", id: "A"),
            call("Bash", id: "s1", parent: "A"), result("s1", parent: "A", error: true),
            call("Bash", id: "s2", parent: "A"), result("s2", parent: "A", error: true),
            result("A", error: false),
            call("Bash", id: "b2"), result("b2", error: true),
            call("Bash", id: "b3"), result("b3"),
        ]

        let g = try onlyGroup(blocks)

        XCTAssertEqual(g.failedCount, 2)
    }

    func testAnErrorFromOnlyASubagentIsNotAFailureOfTheGroup() throws {
        let g = try onlyGroup([call("Agent", id: "A"), call("Bash", id: "s", parent: "A"),
                               result("s", parent: "A", error: true), result("A")])

        XCTAssertEqual(g.failedCount, 0)
    }

    // MARK: State

    func testAnOpenTurnWhoseLastItemIsAGroupWithAnUnfinishedCallIsRunning() throws {
        let g = try onlyGroup([prose, call(id: "a"), result("a"), call(id: "b")], .open)

        XCTAssertEqual(g.state, .running)
        XCTAssertEqual(g.runningCall, 3)
        XCTAssertEqual(g.finishedCount, 1)
    }

    func testHiddenBlocksAfterTheGroupDoNotStopItRunning() throws {
        let g = try onlyGroup([call(id: "a"), .hidden, whitespace], .open)

        XCTAssertEqual(g.state, .running)
        XCTAssertEqual(g.runningCall, 0)
    }

    func testAGroupSettlesWhenProseFollowsItEvenWhileTheTurnIsOpen() throws {
        let items = plan([call(id: "a"), result("a"), call(id: "b"), prose], .open)

        let g = try XCTUnwrap(groups(items).first)
        XCTAssertEqual(g.state, .settled)
        XCTAssertNil(g.runningCall)
    }

    func testAGroupWithEveryCallFinishedIsSettledEvenWhileTheTurnIsOpen() throws {
        let g = try onlyGroup([call(id: "a"), result("a"), call(id: "b"), result("b")], .open)

        XCTAssertEqual(g.state, .settled)
        XCTAssertNil(g.runningCall)
    }

    func testAnEarlierGroupOfAnOpenTurnIsNotRunning() throws {
        let found = groups(plan([call(id: "a"), prose, call(id: "b")], .open))

        XCTAssertEqual(found.count, 2)
        XCTAssertNotEqual(found[0].state, .running)
        XCTAssertEqual(found[1].state, .running)
    }

    func testAnInterruptedTurnStopsTheGroupThatHadAnUnfinishedCall() throws {
        let g = try onlyGroup([call(id: "a"), result("a"), call(id: "b")], .interrupted)

        XCTAssertEqual(g.state, .stopped)
        XCTAssertNil(g.runningCall)
    }

    func testAnInterruptedTurnWhoseCallsAllFinishedIsSettledNotStopped() throws {
        let g = try onlyGroup([call(id: "a"), result("a")], .interrupted)

        XCTAssertEqual(g.state, .settled)
    }

    func testAnyOtherEndSettlesAGroupWithAnUnfinishedCall() throws {
        for outcome in [FoldOutcome.completedOk, .completedError, .errored] {
            let g = try onlyGroup([call(id: "a"), call(id: "b")], outcome)
            XCTAssertEqual(g.state, .settled, "\(outcome)")
            XCTAssertNil(g.runningCall, "\(outcome)")
        }
    }

    // MARK: Stuck

    func testAnErroredTurnsLastFailedGroupIsStuckAndEarlierOnesAreNot() {
        let blocks: [FoldBlock] = [
            call(id: "a"), result("a", error: true), prose,
            call(id: "b"), result("b", error: true),
        ]
        for outcome in [FoldOutcome.completedError, .errored] {
            let found = groups(plan(blocks, outcome))
            XCTAssertEqual(found.map(\.isStuck), [false, true], "\(outcome)")
        }
    }

    func testAnInterruptedTurnIsNeverStuck() {
        let found = groups(plan([call(id: "a"), result("a", error: true)], .interrupted))

        XCTAssertEqual(found.map(\.isStuck), [false])
    }

    func testACompletedOkTurnIsNeverStuckEvenWithFailures() {
        let found = groups(plan([call(id: "a"), result("a", error: true)], .completedOk))

        XCTAssertEqual(found.map(\.isStuck), [false])
    }

    func testAnOpenTurnIsNeverStuck() {
        let found = groups(plan([call(id: "a"), result("a", error: true)], .open))

        XCTAssertEqual(found.map(\.isStuck), [false])
    }

    func testAnErroredTurnWhoseOnlyFailuresAreASubagentsHasNoStuckGroup() {
        let blocks: [FoldBlock] = [call("Agent", id: "A"), call("Bash", id: "s", parent: "A"),
                                   result("s", parent: "A", error: true), result("A")]

        XCTAssertEqual(groups(plan(blocks, .completedError)).map(\.isStuck), [false])
    }

    // MARK: Times

    func testStartedAtIsTheFirstTopLevelCallsStart() throws {
        let g = try onlyGroup([call("Bash", id: "a", started: 10), result("a", at: 11),
                               call("Bash", id: "b", started: 12), result("b", at: 13)])

        XCTAssertEqual(g.startedAt, at(10))
    }

    func testStartedAtIsNilWhenTheFirstCallHasNoStartTime() throws {
        let g = try onlyGroup([call("Bash", id: "a"), result("a", at: 11),
                               call("Bash", id: "b", started: 12), result("b", at: 13)])

        XCTAssertNil(g.startedAt)
    }

    func testStartedAtIgnoresASubagentCallThatComesFirstInTheBlocks() throws {
        let g = try onlyGroup([call("Agent", id: "A", started: 10),
                               call("Bash", id: "s", parent: "A", started: 5), result("s", parent: "A", at: 6),
                               result("A", at: 20)])

        XCTAssertEqual(g.startedAt, at(10))
    }

    func testEndedAtIsTheLatestEndAmongTopLevelCalls() throws {
        // b's result lands after c's: the latest end wins, not the last call's.
        let g = try onlyGroup([call(id: "a", started: 0), call(id: "b", started: 1), call(id: "c", started: 2),
                               result("a", at: 3), result("c", at: 4), result("b", at: 9)])

        XCTAssertEqual(g.endedAt, at(9))
    }

    func testEndedAtUsesFinishedAtForACallThatFinishedQuietly() throws {
        let g = try onlyGroup([call(id: "a", started: 0), result("a", at: 3), call(id: "b", started: 4, finished: 7)])

        XCTAssertEqual(g.endedAt, at(7))
    }

    func testEndedAtIsNilWhenAnyTopLevelCallsEndIsUnknown() throws {
        let noEndAtAll = try onlyGroup([call(id: "a", started: 0), result("a", at: 3), call(id: "b", started: 4), result("b")])
        let unfinished = try onlyGroup([call(id: "a", started: 0), result("a", at: 3), call(id: "b", started: 4)], .open)

        XCTAssertNil(noEndAtAll.endedAt)
        XCTAssertNil(unfinished.endedAt)
    }

    func testEndedAtIgnoresSubagentResults() throws {
        let g = try onlyGroup([call("Agent", id: "A", started: 0),
                               call("Bash", id: "s", parent: "A", started: 1), result("s", parent: "A", at: 50),
                               result("A", at: 4)])

        XCTAssertEqual(g.endedAt, at(4))
    }

    // MARK: Keys

    func testKeyIsTheFirstCallsToolUseId() throws {
        let g = try onlyGroup([call(id: "toolu_first"), result("toolu_first"), call(id: "toolu_second")])

        XCTAssertEqual(g.key, "g:toolu_first")
    }

    func testKeyWithoutAnIdUsesTheTurnKeyAndTheFirstCallsOrdinalInTheTurn() {
        let blocks: [FoldBlock] = [call(), call(), call(), prose, call(), call()]

        let found = groups(plan(blocks, key: "turn-9"))

        XCTAssertEqual(found.map(\.key), ["g:turn-9#c0", "g:turn-9#c3"])
    }

    func testOrdinalsCountTopLevelCallsOnlyNotSubagentCalls() {
        let blocks: [FoldBlock] = [
            call("Agent"),                                // top-level 0
            call("Bash", parent: "?"), call("Bash", parent: "?"),
            call("Bash"),                                 // top-level 1
            prose,
            call("Bash"),                                 // top-level 2
        ]

        let found = groups(plan(blocks, .open, key: "k"))

        XCTAssertEqual(found.map(\.key), ["g:k#c0", "g:k#c2"])
    }

    func testTwoTurnsWithoutIdsGetKeysDistinguishedByTheirTurnKey() {
        let blocks: [FoldBlock] = [call(), call()]

        let a = groups(plan(blocks, key: "turn-a")).map(\.key)
        let b = groups(plan(blocks, key: "turn-b")).map(\.key)

        XCTAssertNotEqual(a, b)
    }

    // MARK: Incremental behaviour

    func testFeedingEmitsOpsThatBuildTheItemsAsTheTurnStreams() throws {
        var planner = ToolFoldPlanner(turnKey: "T")

        XCTAssertEqual(planner.feed(prose), [.block(0)])
        let first = planner.feed(call(id: "a"))
        guard case .group(let g)? = first.first, first.count == 1 else { return XCTFail("a call opens a group: \(first)") }
        XCTAssertEqual(g.id, 0)
        XCTAssertEqual(g.state, .running)

        let second = planner.feed(result("a"))
        guard case .extend(let g2)? = second.first, second.count == 1 else { return XCTFail("a result extends the group: \(second)") }
        XCTAssertEqual(g2.id, 0)
        XCTAssertEqual(g2.finishedCount, 1)

        XCTAssertEqual(planner.blockCount, 3)
        XCTAssertEqual(shape(planner.items()), ["b0", "g0"])
    }

    func testAHiddenBlockChangesNothingOnScreenSoItEmitsNoOps() {
        var planner = ToolFoldPlanner(turnKey: "T")
        _ = planner.feed(call(id: "a"))

        XCTAssertEqual(planner.feed(.hidden), [])
        XCTAssertEqual(planner.blockCount, 2)
    }

    func testEachFedBlockEmitsAtMostTwoOpsWhateverTheTurnLength() {
        // Streaming cost is constant per block: never a re-plan of the whole turn.
        var planner = ToolFoldPlanner(turnKey: "T")
        let blocks = HostileContent.fiveThousandGroups()
        var total = 0

        for block in blocks {
            let ops = planner.feed(block)
            XCTAssertLessThanOrEqual(ops.count, 2)
            total += ops.count
        }
        total += planner.turnEnded(outcome: .completedOk).count

        XCTAssertLessThanOrEqual(total, 2 * blocks.count + 2)
    }

    func testFiveThousandGroupsInOneTurnAreFiveThousandGroups() {
        let blocks = HostileContent.fiveThousandGroups()

        let items = plan(blocks)

        XCTAssertEqual(blocks.count, 15_000)
        XCTAssertEqual(groups(items).count, 5_000)
        XCTAssertEqual(items.count, 10_000)
        XCTAssertEqual(groups(items).map(\.id), Array(0 ..< 5_000))
        XCTAssertTrue(groups(items).allSatisfy { $0.callCount == 1 && $0.state == .settled })
    }

    func testReplayingTheOpsOfATurnGivesTheBatchPlan() {
        let blocks: [FoldBlock] = [prose, call(id: "a"), result("a"), call(id: "b"), .boundary(.askQuestion), call(id: "c"), result("c"), prose]
        var planner = ToolFoldPlanner(turnKey: "T")
        var ops: [ToolFoldPlanner.Op] = []
        for block in blocks { ops += planner.feed(block) }
        ops += planner.turnEnded(outcome: .completedOk)

        XCTAssertEqual(ToolFoldPlanner.replay(ops), plan(blocks, .completedOk))
        XCTAssertEqual(planner.items(), plan(blocks, .completedOk))
    }

    // MARK: Property: incremental == batch

    func testIncrementalPlanningMatchesBatchPlanningForFiveHundredRandomTurns() {
        for n in 0 ..< 500 {
            var rng = SplitMix64(seed: UInt64(n) &* 7_919 &+ 1)
            let blocks = randomTurn(&rng)
            let outcome = [FoldOutcome.open, .open, .completedOk, .completedError, .interrupted, .errored][Int(rng.next() % 6)]
            let context = "sequence \(n), outcome \(outcome), \(blocks.count) blocks"

            var planner = ToolFoldPlanner(turnKey: "turn-\(n)")
            var allOps: [ToolFoldPlanner.Op] = []
            var replayed: [ToolFoldPlanner.Item] = []
            for block in blocks {
                let ops = planner.feed(block)
                allOps += ops
                replayed = ToolFoldPlanner.replay(ops, onto: replayed)
                XCTAssertEqual(replayed, planner.items(), "after feeding: \(context)")
            }
            XCTAssertEqual(planner.blockCount, blocks.count, context)
            if outcome != .open {
                let ops = planner.turnEnded(outcome: outcome)
                allOps += ops
                replayed = ToolFoldPlanner.replay(ops, onto: replayed)
                XCTAssertEqual(replayed, planner.items(), "after turnEnded: \(context)")
            }

            let batch = ToolFoldPlanner.plan(blocks: blocks, outcome: outcome, turnKey: "turn-\(n)")
            XCTAssertEqual(ToolFoldPlanner.replay(allOps), batch, "replay vs plan: \(context)")
            XCTAssertEqual(planner.items(), batch, "items vs plan: \(context)")
            assertEveryBlockAppearsAtMostOnce(batch, blockCount: blocks.count, context)
        }
    }

    /// A block is never rendered twice: not as two items, nor as an item and a member, nor as a
    /// member of two groups. Groups are numbered 0, 1, 2 in order.
    private func assertEveryBlockAppearsAtMostOnce(_ items: [ToolFoldPlanner.Item], blockCount: Int, _ context: String) {
        var seen = Set<Int>()
        var nextGroup = 0
        func claim(_ index: Int) {
            XCTAssertTrue((0 ..< blockCount).contains(index), "index \(index) out of range: \(context)")
            XCTAssertTrue(seen.insert(index).inserted, "block \(index) shown twice: \(context)")
        }
        for item in items {
            switch item {
            case .block(let i):
                claim(i)
            case .group(let g):
                XCTAssertEqual(g.id, nextGroup, context)
                nextGroup += 1
                XCTAssertGreaterThanOrEqual(g.callCount, 1, "a group has a call: \(context)")
                g.memberIndices.forEach(claim)
                g.subagentBlocks.values.joined().forEach(claim)
                XCTAssertEqual(g.callIndices.count, g.calls.count, context)
                XCTAssertTrue(g.callIndices.allSatisfy(g.memberIndices.contains), context)
                XCTAssertEqual(g.memberIndices, g.memberIndices.sorted(), context)
                XCTAssertLessThanOrEqual(g.finishedCount, g.callCount, context)
            }
        }
    }

    private func randomTurn(_ rng: inout SplitMix64) -> [FoldBlock] {
        let names = ["Bash", "Read", "Edit", "Agent", "Task", "Agent", "Grep", "mcp__srv__tool", "Frobnicate"]
        var callIds: [String] = []
        var agentIds: [String] = []
        var serial = 0
        var blocks: [FoldBlock] = []

        func chance(_ percent: UInt64) -> Bool { rng.next() % 100 < percent }
        func pick<T>(_ array: [T]) -> T { array[Int(rng.next() % UInt64(array.count))] }
        func date() -> Date? { chance(70) ? at(Double(serial)) : nil }
        func parent() -> String? {
            guard chance(30) else { return nil }
            switch rng.next() % 3 {
            case 0: return "?"
            case 1: return agentIds.isEmpty ? "unknown" : pick(agentIds)
            default: return "unknown"
            }
        }

        for _ in 0 ..< Int(rng.next() % 41) {
            serial += 1
            switch rng.next() % 12 {
            case 0, 1, 2, 3:
                let name = pick(names)
                let id: String? = chance(80) ? "c\(serial)" : nil
                if let id {
                    callIds.append(id)
                    if name == "Agent" || name == "Task" { agentIds.append(id) }
                }
                blocks.append(.toolCall(FoldCall(name: name, toolUseId: id, parentId: parent(), target: chance(50) ? "f\(serial % 4)" : nil,
                                                 startedAt: date(), finishedAt: chance(10) ? at(Double(serial) + 1) : nil)))
            case 4, 5, 6:
                let id: String? = callIds.isEmpty || chance(25) ? (chance(50) ? nil : "ghost\(serial)") : pick(callIds)
                blocks.append(.toolResult(FoldResult(toolUseId: id, parentId: parent(), isError: chance(25), at: date())))
            case 7:
                blocks.append(.prose(nonEmpty: true, parentId: parent()))
            case 8:
                blocks.append(.prose(nonEmpty: false))
            case 9:
                blocks.append(.boundary(pick([.askQuestion, .errorMessage, .note, .resultSummary, .other])))
            default:
                blocks.append(.hidden)
            }
        }
        return blocks
    }
}

/// Deterministic random numbers, so a failing sequence number reproduces.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
