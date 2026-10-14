import XCTest
@testable import NostromoKit

/// The Focus layout rule (PRD "Conversation versus activity", "How a turn is laid out in
/// Focus"; design contract §2.1): which blocks are conversation and which are activity, how a
/// turn lays out, how the layout moves while the turn streams, and how an activity row is
/// named so its fold state survives.
final class FocusPlannerTests: XCTestCase {

    // MARK: Builders

    private let t0 = Date(timeIntervalSince1970: 3_000_000)
    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    private let prose = FoldBlock.prose(nonEmpty: true)
    private let blank = FoldBlock.prose(nonEmpty: false)
    private let card = FoldBlock.boundary(.askQuestion)

    private func call(_ name: String = "Bash", id: String? = nil, parent: String? = nil, started: Double? = nil) -> FoldBlock {
        .toolCall(FoldCall(name: name, toolUseId: id, parentId: parent, startedAt: started.map(at)))
    }

    private func result(_ id: String?, parent: String? = nil, error: Bool = false, at seconds: Double? = nil) -> FoldBlock {
        .toolResult(FoldResult(toolUseId: id, parentId: parent, isError: error, at: seconds.map(at)))
    }

    /// `count` calls with results: ids `<prefix>1` ... `<prefix>count`.
    private func tools(_ prefix: String, _ count: Int = 1) -> [FoldBlock] {
        (1 ... count).flatMap { [call(id: "\(prefix)\($0)"), result("\(prefix)\($0)")] }
    }

    private func plan(_ blocks: [FoldBlock], _ outcome: FoldOutcome = .completedOk, key: String = "T") -> [FocusItem] {
        FocusPlanner.plan(blocks: blocks, outcome: outcome, turnKey: key)
    }

    /// `act[m0,g0,...]`, `msg<ordinal>`, `b<block index>`, `grp<id>`.
    private func shape(_ items: [FocusItem]) -> [String] {
        items.map { item in
            switch item {
            case .activity(let s):
                return "act[" + s.members.map { member -> String in
                    switch member {
                    case .message(let m): return "m\(m.ordinal)"
                    case .group(let g): return "g\(g.id)"
                    }
                }.joined(separator: ",") + "]"
            case .message(let m): return "msg\(m.ordinal)"
            case .boundary(let i): return "b\(i)"
            case .group(let g): return "grp\(g.id)"
            }
        }
    }

    private func segments(_ items: [FocusItem]) -> [ActivitySegment] {
        items.compactMap { if case .activity(let s) = $0 { return s } else { return nil } }
    }

    private func latest(_ items: [FocusItem]) -> MessageRef? {
        for case .message(let m) in items { return m }
        return nil
    }

    private func isGroupChanged(_ op: FocusOp) -> Bool {
        if case .groupChanged = op { return true }
        return false
    }

    private func nonGroupOps(_ ops: [FocusOp]) -> [FocusOp] { ops.filter { !isGroupChanged($0) } }

    private func kinds(_ ops: [FocusOp]) -> [String] {
        ops.map { op in
            switch op {
            case .item: return "item"
            case .rollIn: return "rollIn"
            case .latestChanged: return "latest"
            case .segmentChanged: return "segment"
            case .groupChanged: return "group"
            }
        }
    }

    // MARK: - Classification and layout (batch)

    func testProseFourCallsProseThreeCallsProseFoldsIntoOneRowThenTheLatestMessageThenTheChip() throws {
        var blocks: [FoldBlock] = [prose]               // 0: A
        blocks += tools("a", 4)                         // 1...8
        blocks.append(prose)                            // 9: B
        blocks += tools("b", 3)                         // 10...15
        blocks.append(prose)                            // 16: C
        blocks.append(.boundary(.resultSummary))        // 17

        let items = plan(blocks)

        XCTAssertEqual(shape(items), ["act[m0,g0,m1,g1]", "msg2", "b17"])
        let row = try XCTUnwrap(segments(items).first)
        XCTAssertEqual(row.messageCount, 2)
        XCTAssertEqual(row.calls.count, 7)
        XCTAssertEqual(row.key, "a:m:T#0")
        XCTAssertEqual(latest(items), MessageRef(ordinal: 2, blockIndices: [16]))
        XCTAssertFalse(row.isLive, "the turn is over")
    }

    func testAMessageFollowedByToolsAndNoFurtherMessageKeepsTheGroupBelowItWithNoRow() {
        let blocks: [FoldBlock] = [prose] + tools("a", 4) + [.boundary(.resultSummary)]

        let items = plan(blocks)

        XCTAssertEqual(shape(items), ["msg0", "grp0", "b9"])
        XCTAssertTrue(segments(items).isEmpty)
    }

    func testASingleMessageHasNoActivityRow() {
        XCTAssertEqual(shape(plan([prose])), ["msg0"])
        XCTAssertEqual(shape(plan([prose, .boundary(.resultSummary)])), ["msg0", "b1"])
    }

    func testTwoTextBlocksSeparatedOnlyByAHiddenBlockAreOneMessage() {
        let items = plan([prose, .hidden, prose])

        XCTAssertEqual(shape(items), ["msg0"])
        XCTAssertEqual(latest(items)?.blockIndices, [0, 1, 2])
    }

    func testHiddenAndWhitespaceBlocksBeforeTheFirstOrAfterTheLastTextAreNotPartOfTheMessage() {
        XCTAssertEqual(latest(plan([.hidden, blank, prose, .hidden, blank]))?.blockIndices, [2])
        XCTAssertEqual(latest(plan([.hidden, prose, .hidden, .hidden, prose, blank, prose, .hidden]))?.blockIndices, [1, 2, 3, 4, 5, 6])
    }

    func testWhitespaceOnlyTextBetweenTwoTextBlocksDoesNotSplitTheMessage() {
        let items = plan([prose, blank, prose])

        XCTAssertEqual(shape(items), ["msg0"])
        XCTAssertEqual(latest(items)?.blockIndices, [0, 1, 2])
    }

    func testAWhitespaceOnlyTurnHasNoMessageAndNoItemForIt() {
        XCTAssertEqual(plan([blank]), [])
        XCTAssertEqual(plan([blank, blank, blank]), [])
        XCTAssertEqual(shape(plan([blank, blank, .boundary(.resultSummary)])), ["b2"])
        XCTAssertEqual(shape(plan([blank] + tools("a"))), ["grp0"])
    }

    func testSubagentProseIsNeverAMessageAndOneWithNowhereToGoIsABoundaryThatSplitsLikeAnUnattachedResult() {
        // Subagent prose TF2 cannot attach to an Agent call is an orphan: like an orphaned
        // result it is rendered as itself (a boundary), never a message and never dropped.
        // The full table is in "Orphan subagent prose" below.
        let split = plan([prose, subProse("x"), prose])

        XCTAssertEqual(shape(split), ["act[m0]", "b1", "msg1"])
        XCTAssertEqual(latest(split)?.blockIndices, [2])
        for message in messageRefs(split) {
            XCTAssertFalse(message.blockIndices.contains(1), "the orphan is never part of a message")
        }
        XCTAssertEqual(shape(plan([subProse("x")])), ["b0"])
        XCTAssertEqual(shape(plan([subProse("?")])), ["b0"])
    }

    func testSubagentProseAttachedToAnEarlierAgentCallDoesNotSplitTheMessageEither() throws {
        let blocks: [FoldBlock] = [
            call("Agent", id: "a"),                          // 0
            result("a"),                                     // 1
            prose,                                           // 2
            .prose(nonEmpty: true, parentId: "a"),           // 3: TF2 attaches it to the Agent call
            prose,                                           // 4
        ]

        let items = plan(blocks)

        XCTAssertEqual(shape(items), ["act[g0]", "msg0"])
        let message = try XCTUnwrap(latest(items))
        XCTAssertEqual(message.blockIndices.first, 2)
        XCTAssertEqual(message.blockIndices.last, 4)
    }

    func testSubagentTrafficStaysInsideItsAgentCall() throws {
        let blocks: [FoldBlock] = [
            call("Agent", id: "a"),
            .prose(nonEmpty: true, parentId: "a"),
            call("Bash", id: "s1", parent: "a"),
            result("s1", parent: "a", error: true),
            result("a"),
            prose,
        ]

        let items = plan(blocks)

        XCTAssertEqual(shape(items), ["act[g0]", "msg0"])
        let row = try XCTUnwrap(segments(items).first)
        XCTAssertEqual(row.calls.map(\.name), ["Agent"], "the subagent's own call is not a top-level call")
        XCTAssertEqual(row.failedCount, 0, "a subagent's failure is not the row's")
    }

    func testAnAgentTurnWithOnlySubagentTrafficAndNoMessageIsJustItsGroup() {
        let blocks: [FoldBlock] = [call("Agent", id: "a"), .prose(nonEmpty: true, parentId: "a"), result("a")]

        XCTAssertEqual(shape(plan(blocks)), ["grp0"])
    }

    func testTheLatestMessageIsTheLastRunOfTextWhateverFollowsIt() {
        // Hidden and whitespace blocks after it do not start another message.
        let items = plan([prose] + tools("a") + [prose, blank, .hidden])

        XCTAssertEqual(shape(items), ["act[m0,g0]", "msg1"])
        XCTAssertEqual(latest(items)?.blockIndices, [3])
    }

    func testMessageOrdinalsCountFromZeroAcrossTheWholeTurn() {
        let blocks: [FoldBlock] = [prose] + tools("a") + [prose] + tools("b") + [prose] + tools("c") + [prose]

        let items = plan(blocks)

        XCTAssertEqual(shape(items), ["act[m0,g0,m1,g1,m2,g2]", "msg3"])
    }

    func testTextAcrossATopLevelCallOrResultIsTwoMessages() {
        XCTAssertEqual(shape(plan([prose, call(id: "a"), prose])), ["act[m0,g0]", "msg1"])
        XCTAssertEqual(shape(plan([prose, call(id: "a"), result("a"), prose, result(nil), prose])), ["act[m0,g0,m1]", "b4", "msg2"])
    }

    // MARK: Boundaries

    func testAnAskCardBetweenTwoRunsOfActivitySplitsTheRowAndStaysWhereItHappened() {
        let blocks: [FoldBlock] = tools("a") + [card] + tools("b") + [prose]

        let items = plan(blocks)

        XCTAssertEqual(shape(items), ["act[g0]", "b2", "act[g1]", "msg0"])
        XCTAssertEqual(segments(items).map(\.key), ["a:g:a1", "a:g:b1"])
    }

    func testAMidTurnCardWithMessagesOnBothSidesGivesTwoRows() {
        let blocks: [FoldBlock] = [prose] + tools("a") + [card, prose] + tools("b") + [prose]

        let items = plan(blocks)

        XCTAssertEqual(shape(items), ["act[m0,g0]", "b3", "act[m1,g1]", "msg2"])
        XCTAssertEqual(segments(items).map(\.key), ["a:m:T#0", "a:m:T#1"])
    }

    func testAFinalUnansweredCardSitsBelowTheLatestMessage() {
        XCTAssertEqual(shape(plan([prose, card], .open)), ["msg0", "b1"])
        XCTAssertEqual(shape(plan([prose] + tools("a") + [card], .open)), ["msg0", "grp0", "b3"])
        XCTAssertEqual(shape(plan([prose] + tools("a") + [prose, card], .open)), ["act[m0,g0]", "msg1", "b4"])
    }

    func testEveryKindOfBoundaryIsItsOwnItemAndSplitsTheRow() {
        let kinds: [FoldBoundaryKind] = [.askQuestion, .errorMessage, .note, .resultSummary, .other]
        for kind in kinds {
            let items = plan(tools("a") + [.boundary(kind)] + tools("b") + [prose])

            XCTAssertEqual(shape(items), ["act[g0]", "b2", "act[g1]", "msg0"], "\(kind)")
        }
    }

    func testBoundariesAfterTheLatestMessageComeAfterItInOrder() {
        let blocks: [FoldBlock] = [prose, .boundary(.note), .boundary(.errorMessage), .boundary(.resultSummary)]

        XCTAssertEqual(shape(plan(blocks)), ["msg0", "b1", "b2", "b3"])
    }

    func testATurnWithNoMessageShowsOnlyItsGroupsAndBoundaries() {
        let blocks: [FoldBlock] = tools("a") + [card] + [call(id: "b")] + [.boundary(.resultSummary)]

        let items = plan(blocks)

        XCTAssertEqual(shape(items), ["grp0", "b2", "grp1", "b4"])
        XCTAssertTrue(segments(items).isEmpty)
        XCTAssertNil(latest(items))
    }

    func testTextThenACardThenTextFoldsTheFirstTextIntoARowOfJustThatMessage() throws {
        // What the daemon's CONFIRM: split produces.
        let items = plan([prose, card, prose], .open)

        XCTAssertEqual(shape(items), ["act[m0]", "b1", "msg1"])
        let row = try XCTUnwrap(segments(items).first)
        XCTAssertEqual(row.messageCount, 1)
        XCTAssertEqual(row.calls.count, 0)
        XCTAssertEqual(row.key, "a:m:T#0")
    }

    func testAnOrphanedResultIsABoundaryAndSplitsAMessage() {
        // Nothing to belong to: TF2 renders it as itself.
        XCTAssertEqual(shape(plan([prose, result(nil)])), ["msg0", "b1"])
        XCTAssertEqual(shape(plan([prose, result(nil), prose])), ["act[m0]", "b1", "msg1"])
    }

    // MARK: Row liveness

    func testTheLastRowOfAnOpenTurnIsLiveAndNoRowOfAFinishedTurnIs() {
        let blocks: [FoldBlock] = [prose] + tools("a") + [card, prose] + tools("b") + [prose]

        let open = segments(plan(blocks, .open))
        XCTAssertEqual(open.map(\.isLive), [false, true])
        for outcome: FoldOutcome in [.completedOk, .completedError, .interrupted, .errored] {
            XCTAssertEqual(segments(plan(blocks, outcome)).map(\.isLive), [false, false], "\(outcome)")
        }
    }

    // MARK: Failure and stuck inside rows

    func testARowCountsAFailureOfAnyCallInIt() throws {
        let blocks: [FoldBlock] = [prose, call(id: "a"), result("a", error: true), call(id: "b"), result("b"), prose, call(id: "c"), result("c", error: true), prose]

        let row = try XCTUnwrap(segments(plan(blocks)).first)

        XCTAssertEqual(row.failedCount, 2)
    }

    func testAStuckGroupFoldedIntoARowMakesTheRowContainIt() throws {
        let blocks: [FoldBlock] = [call(id: "a"), result("a", error: true), prose]

        let stuck = try XCTUnwrap(segments(plan(blocks, .completedError)).first)
        let calm = try XCTUnwrap(segments(plan(blocks, .completedOk)).first)

        XCTAssertTrue(stuck.containsStuckGroup)
        XCTAssertFalse(calm.containsStuckGroup)
    }

    func testAnInterruptedTurnsUnfinishedGroupInsideARowReadsAsStopped() throws {
        let blocks: [FoldBlock] = [call(id: "a"), prose]

        let row = try XCTUnwrap(segments(plan(blocks, .interrupted)).first)

        guard case .group(let g)? = row.members.first else { return XCTFail("expected the group first") }
        XCTAssertEqual(g.state, .stopped)
    }

    func testGroupsAreExactlyTheToolFoldPlannersGroups() {
        let blocks: [FoldBlock] = [prose, call("Agent", id: "a", started: 1), .prose(nonEmpty: true, parentId: "a"), result("a", at: 4),
                                   prose, call(id: "b", started: 5), prose, call(id: "c")]
        for outcome: FoldOutcome in [.open, .completedOk, .interrupted] {
            let tf2 = ToolFoldPlanner.plan(blocks: blocks, outcome: outcome, turnKey: "T").compactMap { item -> ToolGroup? in
                if case .group(let g) = item { return g } else { return nil }
            }
            XCTAssertEqual(allGroups(plan(blocks, outcome)), tf2, "\(outcome)")
        }
    }

    /// Every message the items show, folded or latest, in order.
    private func messageRefs(_ items: [FocusItem]) -> [MessageRef] {
        var out: [MessageRef] = []
        for item in items {
            switch item {
            case .activity(let s):
                for case .message(let m) in s.members { out.append(m) }
            case .message(let m): out.append(m)
            default: break
            }
        }
        return out
    }

    /// Subagent prose. Whether it attaches depends on the Agent calls before it.
    private func subProse(_ parent: String, nonEmpty: Bool = true) -> FoldBlock {
        .prose(nonEmpty: nonEmpty, parentId: parent)
    }

    private func allGroups(_ items: [FocusItem]) -> [ToolGroup] {
        var out: [ToolGroup] = []
        for item in items {
            switch item {
            case .activity(let s):
                for case .group(let g) in s.members { out.append(g) }
            case .group(let g): out.append(g)
            default: break
            }
        }
        return out
    }

    // MARK: - Keys (contract §2.3)

    func testARowThatStartsWithAMessageIsKeyedByThatMessagesOrdinal() {
        let items = plan([prose] + tools("a") + [prose])

        XCTAssertEqual(segments(items).map(\.key), ["a:m:T#0"])
        XCTAssertEqual(plan([prose] + tools("a") + [prose], key: "turn-9").compactMap { if case .activity(let s) = $0 { return s.key } else { return nil } },
                       ["a:m:turn-9#0"])
    }

    func testARowThatStartsWithAGroupIsKeyedByThatGroupsKey() {
        let items = plan([call(id: "toolu_01"), result("toolu_01"), call(id: "toolu_02"), result("toolu_02"), prose])

        XCTAssertEqual(segments(items).map(\.key), ["a:g:toolu_01"])
    }

    func testAGroupWithoutAnIdFallsBackToTheTurnKeyedGroupKey() {
        let items = plan([call(), result(nil), prose])

        XCTAssertEqual(segments(items).map(\.key), ["a:g:T#c0"])
    }

    func testTheSecondRowOfATurnIsKeyedByItsOwnFirstMember() {
        let items = plan([prose] + tools("a") + [card] + tools("b") + [prose, card, prose])

        XCTAssertEqual(shape(items), ["act[m0,g0]", "b3", "act[g1,m1]", "b7", "msg2"])
        XCTAssertEqual(segments(items).map(\.key), ["a:m:T#0", "a:g:b1"])
    }

    func testTheSameBlocksGiveTheSameKeysWhetherPlannedAtOnceOrFedOneByOneOrFedAgain() {
        let blocks: [FoldBlock] = [prose] + tools("a") + [card, prose] + tools("b", 2) + [prose, card, call(id: "c"), prose, call(id: "d")]
        let batch = segments(plan(blocks, .open)).map(\.key)

        var first = FocusPlanner(turnKey: "T")
        var second = FocusPlanner(turnKey: "T")
        for block in blocks { _ = first.feed(block) }
        for block in blocks { _ = second.feed(block) }

        XCTAssertFalse(batch.isEmpty)
        XCTAssertEqual(segments(first.items()).map(\.key), batch)
        XCTAssertEqual(segments(second.items()).map(\.key), batch)
    }

    func testARowsKeyDoesNotChangeWhenLaterMessagesExtendIt() {
        var planner = FocusPlanner(turnKey: "T")
        var items: [FocusItem] = []
        var keys: [String] = []
        let blocks: [FoldBlock] = [prose] + tools("a") + [prose] + tools("b") + [prose] + tools("c") + [prose] + tools("d") + [prose]
        for block in blocks {
            items = FocusPlanner.replay(planner.feed(block), onto: items)
            if let row = segments(items).first { keys.append(row.key) }
        }

        XCTAssertEqual(Set(keys), ["a:m:T#0"])
        XCTAssertEqual(segments(items).count, 1)
        XCTAssertEqual(segments(items).first?.messageCount, 4)
    }

    func testAGroupFirstRowKeepsItsKeyWhenAMessageThenExtendsIt() {
        var planner = FocusPlanner(turnKey: "T")
        var items: [FocusItem] = []
        var keys: [String] = []
        for block in tools("a") + [prose] + tools("b") + [prose] {
            items = FocusPlanner.replay(planner.feed(block), onto: items)
            if let row = segments(items).first { keys.append(row.key) }
        }

        XCTAssertEqual(Set(keys), ["a:g:a1"])
    }

    func testRemovingANonDurableBoundaryMergesTwoRowsUnderTheFirstRowsKey() {
        // The documented weak spot (contract §2.3): an error message or a result chip that
        // vanishes after a daemon restart joins the rows on either side of it.
        for kind in [FoldBoundaryKind.errorMessage, .resultSummary] {
            let withBoundary: [FoldBlock] = [prose] + tools("a") + [.boundary(kind), prose] + tools("b") + [prose]
            var without = withBoundary
            without.remove(at: 3)

            let split = segments(plan(withBoundary))
            let merged = segments(plan(without))

            XCTAssertEqual(split.map(\.key), ["a:m:T#0", "a:m:T#1"], "\(kind)")
            XCTAssertEqual(merged.map(\.key), [split[0].key], "\(kind): the merged row keeps the first row's key")
            XCTAssertEqual(merged.first?.messageCount, 2, "\(kind)")
        }
    }

    // MARK: - Incremental ops

    /// Feeds blocks to a planner and keeps the replayed items, checking after every step
    /// that they equal both `items()` and the batch plan of the open turn.
    private struct Rig {
        var planner: FocusPlanner
        var items: [FocusItem] = []
        var blocks: [FoldBlock] = []
        var quiet: [(id: String, at: Date?)] = []
        let key: String

        init(_ key: String = "T") {
            self.key = key
            planner = FocusPlanner(turnKey: key)
        }

        /// The blocks as a batch caller would pass them: quiet finishes folded into their calls.
        var batchBlocks: [FoldBlock] {
            blocks.map { block in
                guard case .toolCall(var c) = block, let id = c.toolUseId,
                      let finish = quiet.first(where: { $0.id == id }) else { return block }
                c.finishedAt = finish.at
                c.finishedQuietly = true
                return .toolCall(c)
            }
        }

        @discardableResult
        mutating func feed(_ block: FoldBlock, file: StaticString = #filePath, line: UInt = #line) -> [FocusOp] {
            blocks.append(block)
            let ops = planner.feed(block)
            items = FocusPlanner.replay(ops, onto: items)
            check(file: file, line: line)
            return ops
        }

        @discardableResult
        mutating func feed(_ many: [FoldBlock], file: StaticString = #filePath, line: UInt = #line) -> [FocusOp] {
            var all: [FocusOp] = []
            for block in many { all += feed(block, file: file, line: line) }
            return all
        }

        @discardableResult
        mutating func finish(_ id: String, at when: Date?, file: StaticString = #filePath, line: UInt = #line) -> [FocusOp] {
            let known = blocks.contains { if case .toolCall(let c) = $0 { return c.toolUseId == id } else { return false } }
            let ops = planner.callFinished(toolUseId: id, at: when)
            if known { quiet.append((id, when)) }
            items = FocusPlanner.replay(ops, onto: items)
            check(file: file, line: line)
            return ops
        }

        private func check(file: StaticString, line: UInt) {
            XCTAssertEqual(items, planner.items(), "replayed ops vs items()", file: file, line: line)
            XCTAssertEqual(items, FocusPlanner.plan(blocks: batchBlocks, outcome: .open, turnKey: key),
                           "replayed ops vs the batch plan", file: file, line: line)
        }
    }

    func testTheFirstMessageIsJustTheLatestMessage() {
        var rig = Rig()

        let ops = rig.feed(prose)

        XCTAssertEqual(ops, [.latestChanged(MessageRef(ordinal: 0, blockIndices: [0]))])
        XCTAssertEqual(shape(rig.items), ["msg0"])
    }

    func testMoreTextOfTheSameMessageOnlyGrowsTheLatestMessage() {
        var rig = Rig()
        rig.feed(prose)

        XCTAssertEqual(rig.feed(prose), [.latestChanged(MessageRef(ordinal: 0, blockIndices: [0, 1]))])
        XCTAssertEqual(rig.feed(.hidden), [], "a hidden block changes nothing yet")
        XCTAssertEqual(rig.feed(blank), [], "whitespace changes nothing yet")
        XCTAssertEqual(rig.feed(prose), [.latestChanged(MessageRef(ordinal: 0, blockIndices: [0, 1, 2, 3, 4]))])
        XCTAssertEqual(shape(rig.items), ["msg0"])
    }

    func testBlocksThatAreNeverMessagesEmitNothingBesidesGroupUpdates() {
        var rig = Rig()
        rig.feed(prose)

        // (Non-empty subagent prose with nowhere to go is a boundary now: see "Orphan subagent prose".)
        for block in [FoldBlock.hidden, blank, .prose(nonEmpty: false, parentId: "x"), .prose(nonEmpty: false, parentId: "?")] {
            XCTAssertEqual(nonGroupOps(rig.feed(block)), [], "\(block)")
        }
        XCTAssertEqual(shape(rig.items), ["msg0"])
    }

    func testAToolCallAloneNeverMovesTheLatestMessageOrTouchesARow() throws {
        var rig = Rig()
        rig.feed(prose)

        for n in 1 ... 6 {
            for block in [call(id: "c\(n)"), result("c\(n)", error: n == 3)] {
                for op in rig.feed(block) {
                    switch op {
                    case .item(.group), .groupChanged: break
                    default: XCTFail("a call or result emitted \(op)")
                    }
                }
            }
        }

        XCTAssertEqual(shape(rig.items), ["msg0", "grp0"])
        XCTAssertEqual(latest(rig.items), MessageRef(ordinal: 0, blockIndices: [0]))
        guard case .group(let g)? = rig.items.last else { return XCTFail("expected a trailing group") }
        XCTAssertEqual(g.callCount, 6)
    }

    func testTheFirstCallOfAGroupAppendsTheGroupAndTheRestOnlyUpdateIt() {
        var rig = Rig()

        let first = rig.feed(call(id: "a"))
        let second = rig.feed(call(id: "b"))
        let third = rig.feed(result("a"))

        XCTAssertEqual(kinds(first), ["item"])
        guard case .item(.group(let g))? = first.first else { return XCTFail("expected an appended group, got \(first)") }
        XCTAssertEqual(g.callCount, 1)
        XCTAssertTrue(second.allSatisfy(isGroupChanged))
        XCTAssertTrue(third.allSatisfy(isGroupChanged))
        XCTAssertEqual(shape(rig.items), ["grp0"])
    }

    func testABoundaryIsAppendedAsABoundaryItem() {
        var rig = Rig()
        rig.feed(prose)

        let ops = rig.feed(card)

        XCTAssertEqual(nonGroupOps(ops), [.item(.boundary(1))])
        XCTAssertEqual(shape(rig.items), ["msg0", "b1"])
    }

    func testAnOrphanedResultIsAppendedAsABoundaryItem() {
        var rig = Rig()
        rig.feed(prose)

        let ops = rig.feed(result(nil))

        XCTAssertEqual(nonGroupOps(ops), [.item(.boundary(1))])
    }

    func testANewMessageAfterToolsRollsThePreviousOneAndTheGroupIntoARowWithOneRollInAndOneLatestChange() throws {
        var rig = Rig()
        rig.feed([prose] + tools("a", 4))
        XCTAssertEqual(shape(rig.items), ["msg0", "grp0"])

        let ops = rig.feed(prose)

        XCTAssertEqual(kinds(nonGroupOps(ops)), ["rollIn", "latest"])
        guard case .rollIn(let from, let rolled) = nonGroupOps(ops)[0], case .latestChanged(let newest) = nonGroupOps(ops)[1] else { return XCTFail("\(ops)") }
        XCTAssertEqual(from, 0)
        XCTAssertEqual(shape(rolled), ["act[m0,g0]"])
        XCTAssertFalse(rolled.contains(.message(newest)), "the roll-in never carries the new latest message")
        XCTAssertEqual(newest, MessageRef(ordinal: 1, blockIndices: [9]))
        let row = try XCTUnwrap(segments(rolled).first)
        XCTAssertEqual(row.key, "a:m:T#0")
        XCTAssertEqual(row.calls.count, 4)
        XCTAssertTrue(row.isLive, "the turn is still open")
        XCTAssertEqual(shape(rig.items), ["act[m0,g0]", "msg1"])
    }

    func testTheFirstMessageAfterLeadingToolsTurnsThemIntoARowWithNoMessages() throws {
        var rig = Rig()
        rig.feed(tools("a", 2) + [call(id: "b")])
        XCTAssertEqual(shape(rig.items), ["grp0"])

        let ops = rig.feed(prose)

        XCTAssertEqual(kinds(nonGroupOps(ops)), ["rollIn", "latest"])
        XCTAssertEqual(shape(rig.items), ["act[g0]", "msg0"])
        let row = try XCTUnwrap(segments(rig.items).first)
        XCTAssertEqual(row.key, "a:g:a1")
        XCTAssertEqual(row.messageCount, 0)
    }

    func testTheFirstMessageAfterNothingButACardIsAJustALatestMessage() {
        var rig = Rig()
        rig.feed(card)

        let ops = rig.feed(prose)

        XCTAssertEqual(kinds(nonGroupOps(ops)), ["latest"])
        XCTAssertEqual(shape(rig.items), ["b0", "msg0"])
    }

    func testANewMessageAfterACardRollsThePreviousMessageInBeforeTheCard() {
        var rig = Rig()
        rig.feed([prose, card])

        let ops = rig.feed(prose)

        XCTAssertEqual(kinds(nonGroupOps(ops).filter { if case .segmentChanged = $0 { return false } else { return true } }), ["rollIn", "latest"])
        XCTAssertEqual(shape(rig.items), ["act[m0]", "b1", "msg1"])
    }

    func testALaterMessageExtendsTheRowWithoutChangingItsKey() throws {
        var rig = Rig()
        rig.feed([prose] + tools("a") + [prose] + tools("b"))
        let before = try XCTUnwrap(segments(rig.items).first)

        let ops = rig.feed(prose)

        XCTAssertEqual(ops.filter { if case .rollIn = $0 { return true } else { return false } }.count, 1)
        XCTAssertEqual(ops.filter { if case .latestChanged = $0 { return true } else { return false } }.count, 1)
        let after = try XCTUnwrap(segments(rig.items).first)
        XCTAssertEqual(after.key, before.key)
        XCTAssertEqual(shape(rig.items), ["act[m0,g0,m1,g1]", "msg2"])
    }

    func testAMessageAfterAMidTurnCardRollsInAsItsOwnRowAfterTheCard() throws {
        var rig = Rig()
        rig.feed([prose] + tools("a") + [card, prose] + tools("b"))
        XCTAssertEqual(shape(rig.items), ["act[m0,g0]", "b3", "msg1", "grp1"])
        let firstRow = try XCTUnwrap(segments(rig.items).first)

        let ops = rig.feed(prose)

        XCTAssertEqual(ops.filter { if case .rollIn = $0 { return true } else { return false } }.count, 1)
        XCTAssertEqual(ops.filter { if case .latestChanged = $0 { return true } else { return false } }.count, 1)
        XCTAssertLessThanOrEqual(nonGroupOps(ops).count, 3)
        XCTAssertEqual(shape(rig.items), ["act[m0,g0]", "b3", "act[m1,g1]", "msg2"])
        let rows = segments(rig.items)
        XCTAssertEqual(rows.map(\.key), ["a:m:T#0", "a:m:T#1"])
        XCTAssertEqual(rows[0].key, firstRow.key)
        XCTAssertEqual(rows.map(\.isLive), [false, true], "only the last row of an open turn is live")
    }

    func testTenRollInsEachTakeExactlyOneRollInAndOneLatestChange() {
        var rig = Rig()
        rig.feed(prose)
        for n in 1 ... 10 {
            rig.feed(tools("t\(n)"))
            let ops = rig.feed(prose)

            XCTAssertEqual(ops.filter { if case .rollIn = $0 { return true } else { return false } }.count, 1, "message \(n)")
            XCTAssertEqual(ops.filter { if case .latestChanged = $0 { return true } else { return false } }.count, 1, "message \(n)")
            XCTAssertLessThanOrEqual(nonGroupOps(ops).count, 3, "message \(n)")
        }
        XCTAssertEqual(segments(rig.items).count, 1)
        XCTAssertEqual(segments(rig.items).first?.messageCount, 10)
        XCTAssertEqual(latest(rig.items)?.ordinal, 10)
    }

    func testAGroupFinishingQuietlyUpdatesTheTrailingGroupInPlace() throws {
        var rig = Rig()
        rig.feed([prose, call(id: "a", started: 1)])

        let ops = rig.finish("a", at: at(3))

        XCTAssertEqual(kinds(ops), ["group"])
        guard case .group(let g)? = rig.items.last else { return XCTFail("expected a trailing group") }
        XCTAssertEqual(g.finishedCount, 1)
        XCTAssertEqual(g.calls.first?.finishedAt, at(3))
        XCTAssertEqual(shape(rig.items), ["msg0", "grp0"])
    }

    func testAGroupFinishingQuietlyAfterItRolledIntoARowUpdatesTheGroupInsideTheRow() throws {
        var rig = Rig()
        rig.feed([prose, call(id: "a", started: 1), prose])
        XCTAssertEqual(shape(rig.items), ["act[m0,g0]", "msg1"])

        let ops = rig.finish("a", at: at(3))

        XCTAssertTrue(ops.allSatisfy(isGroupChanged), "\(ops)")
        XCTAssertFalse(ops.isEmpty)
        let row = try XCTUnwrap(segments(rig.items).first)
        guard case .group(let g)? = row.members.last else { return XCTFail("expected the group last") }
        XCTAssertEqual(g.finishedCount, 1)
        XCTAssertEqual(row.endedAt, at(3))
    }

    func testAnUnknownCallFinishingChangesNothing() {
        var rig = Rig()
        rig.feed([prose, call(id: "a")])

        XCTAssertEqual(rig.finish("nope", at: at(1)), [])
    }

    func testEndingTheTurnClearsTheLastRowsLiveFlagWithOneSegmentChange() throws {
        var planner = FocusPlanner(turnKey: "T")
        var items: [FocusItem] = []
        for block in [prose] + tools("a") + [prose] { items = FocusPlanner.replay(planner.feed(block), onto: items) }
        let live = try XCTUnwrap(segments(items).first)
        XCTAssertTrue(live.isLive)

        let ops = planner.turnEnded(outcome: .completedOk)

        let changes = nonGroupOps(ops)
        XCTAssertEqual(changes.count, 1)
        guard case .segmentChanged(let ended)? = changes.first else { return XCTFail("\(ops)") }
        XCTAssertEqual(ended.key, live.key)
        XCTAssertFalse(ended.isLive)
        XCTAssertEqual(ended.members, live.members)
        items = FocusPlanner.replay(ops, onto: items)
        XCTAssertEqual(items, plan([prose] + tools("a") + [prose], .completedOk))
        XCTAssertEqual(items, planner.items())
    }

    func testEndingATurnWithNoRowChangesNoRowButSettlesItsGroups() {
        var planner = FocusPlanner(turnKey: "T")
        var items: [FocusItem] = []
        for block in [prose, call(id: "a")] { items = FocusPlanner.replay(planner.feed(block), onto: items) }

        let ops = planner.turnEnded(outcome: .completedOk)

        XCTAssertEqual(nonGroupOps(ops), [])
        XCTAssertFalse(ops.isEmpty, "the trailing group stops running")
        XCTAssertEqual(FocusPlanner.replay(ops, onto: items), plan([prose, call(id: "a")], .completedOk))
    }

    func testEndingAnInterruptedTurnStopsItsTrailingGroupAndClearsTheLiveRow() {
        let blocks: [FoldBlock] = [prose] + tools("a") + [prose, call(id: "b")]
        var planner = FocusPlanner(turnKey: "T")
        var items: [FocusItem] = []
        for block in blocks { items = FocusPlanner.replay(planner.feed(block), onto: items) }

        let ops = planner.turnEnded(outcome: .interrupted)

        XCTAssertEqual(kinds(ops).filter { $0 == "segment" }.count, 1)
        XCTAssertEqual(kinds(ops).filter { $0 == "rollIn" || $0 == "latest" || $0 == "item" }.count, 0)
        items = FocusPlanner.replay(ops, onto: items)
        XCTAssertEqual(items, plan(blocks, .interrupted))
        XCTAssertEqual(allGroups(items).last?.state, .stopped)
    }

    func testEndingAnErroredTurnPropagatesTheStuckGroupIntoItsRow() throws {
        let blocks: [FoldBlock] = [call(id: "a"), result("a", error: true), prose]
        var planner = FocusPlanner(turnKey: "T")
        var items: [FocusItem] = []
        for block in blocks { items = FocusPlanner.replay(planner.feed(block), onto: items) }
        XCTAssertFalse(try XCTUnwrap(segments(items).first).containsStuckGroup)

        items = FocusPlanner.replay(planner.turnEnded(outcome: .completedError), onto: items)

        XCTAssertTrue(try XCTUnwrap(segments(items).first).containsStuckGroup)
        XCTAssertEqual(items, plan(blocks, .completedError))
    }

    // MARK: - Presentation hold (contract §2.1)

    /// A, 1 call, B, 1 call, C: one row [m0, g0, m1, g1] and the latest message m2.
    private var heldBlocks: [FoldBlock] {
        [prose] + tools("c", 1) + [prose] + [call(id: "d"), result("d")] + [prose]
    }

    private func planner(_ blocks: [FoldBlock], ended outcome: FoldOutcome? = nil) -> FocusPlanner {
        var planner = FocusPlanner(turnKey: "T")
        for block in blocks { _ = planner.feed(block) }
        if let outcome { _ = planner.turnEnded(outcome: outcome) }
        return planner
    }

    func testHoldingAMessageInTheMiddleOfARowSplitsTheRowAroundIt() throws {
        let p = planner(heldBlocks)
        let full = try XCTUnwrap(segments(p.items()).first)

        let held = p.items(holding: [1])

        XCTAssertEqual(shape(held), ["act[m0,g0]", "msg1", "grp1", "msg2"])
        let prefix = try XCTUnwrap(segments(held).first)
        XCTAssertEqual(prefix.key, full.key, "the prefix is the same row")
        XCTAssertEqual(prefix.members, Array(full.members.prefix(2)))
        XCTAssertEqual(held[1], .message(try XCTUnwrap({ () -> MessageRef? in
            if case .message(let m) = full.members[2] { return m } else { return nil } }())))
        XCTAssertEqual(held[2], .group(try XCTUnwrap({ () -> ToolGroup? in
            if case .group(let g) = full.members[3] { return g } else { return nil } }())))
    }

    func testThePrefixKeepsTheRowsLiveFlag() throws {
        let open = try XCTUnwrap(segments(planner(heldBlocks).items(holding: [1])).first)
        let ended = try XCTUnwrap(segments(planner(heldBlocks, ended: .completedOk).items(holding: [1])).first)

        XCTAssertTrue(open.isLive)
        XCTAssertFalse(ended.isLive)
    }

    func testHoldingTheFirstMemberOfARowLeavesNoPrefixAndTheRestStartsANewRowKeyedByItsFirstMember() throws {
        let p = planner(heldBlocks)

        let held = p.items(holding: [0])

        XCTAssertEqual(shape(held), ["msg0", "act[g0,m1,g1]", "msg2"])
        XCTAssertEqual(segments(held).first?.key, "a:g:c1")
    }

    func testAStretchOfOnlyGroupsAfterAHeldMessageIsPlainGroupItems() {
        let p = planner(heldBlocks)

        XCTAssertEqual(shape(p.items(holding: [0, 1])), ["msg0", "grp0", "msg1", "grp1", "msg2"])
    }

    func testHoldingTwoMessagesOfOneRow() throws {
        let blocks = [prose] + tools("c", 1) + [prose] + tools("d", 1) + [prose] + tools("e", 1) + [prose]
        let p = planner(blocks)
        let full = try XCTUnwrap(segments(p.items()).first)
        XCTAssertEqual(shape(p.items()), ["act[m0,g0,m1,g1,m2,g2]", "msg3"])

        let held = p.items(holding: [1, 2])

        XCTAssertEqual(shape(held), ["act[m0,g0]", "msg1", "grp1", "msg2", "grp2", "msg3"])
        XCTAssertEqual(segments(held).first?.key, full.key)
    }

    func testHoldingTheLastRolledInMessageKeepsEverythingBeforeItInTheRow() {
        let blocks = [prose] + tools("c", 1) + [prose] + tools("d", 1) + [prose] + tools("e", 1) + [prose]

        XCTAssertEqual(shape(planner(blocks).items(holding: [2])), ["act[m0,g0,m1,g1]", "msg2", "grp2", "msg3"])
        XCTAssertEqual(shape(planner(blocks).items(holding: [0, 2])), ["msg0", "act[g0,m1,g1]", "msg2", "grp2", "msg3"])
        XCTAssertEqual(planner(blocks).items(holding: [0, 2]).compactMap { if case .activity(let s) = $0 { return s.key } else { return nil } },
                       ["a:g:c1"])
    }

    func testHoldingAMessageInTheSecondRowLeavesTheFirstRowAlone() {
        let blocks = [prose] + tools("a") + [card, prose] + tools("b") + [prose]
        let p = planner(blocks)
        XCTAssertEqual(shape(p.items()), ["act[m0,g0]", "b3", "act[m1,g1]", "msg2"])

        XCTAssertEqual(shape(p.items(holding: [1])), ["act[m0,g0]", "b3", "msg1", "grp1", "msg2"])
        XCTAssertEqual(segments(p.items(holding: [1])).map(\.key), ["a:m:T#0"])
    }

    func testAHeldMessageThatEndsItsRowLeavesNothingAfterIt() {
        // m0, g0, m1, then a card: the row ends with the message.
        let blocks = [prose] + tools("a") + [prose, card, prose]
        let p = planner(blocks)
        XCTAssertEqual(shape(p.items()), ["act[m0,g0,m1]", "b4", "msg2"])

        XCTAssertEqual(shape(p.items(holding: [1])), ["act[m0,g0]", "msg1", "b4", "msg2"])
    }

    func testTrailingGroupsStayBelowTheLatestMessageWhenAMessageIsHeld() {
        let p = planner(heldBlocks + [call(id: "t")])

        XCTAssertEqual(shape(p.items()), ["act[m0,g0,m1,g1]", "msg2", "grp2"])
        XCTAssertEqual(shape(p.items(holding: [1])), ["act[m0,g0]", "msg1", "grp1", "msg2", "grp2"])
    }

    func testHoldingTheLatestMessageOrOneThatNeverRolledOrOneThatDoesNotExistChangesNothing() {
        let rolled = planner(heldBlocks)
        let neverRolled = planner([prose] + tools("a"))

        for ordinals: Set<Int> in [[], [2], [99], [-1], [2, 99]] {
            XCTAssertEqual(rolled.items(holding: ordinals), rolled.items(), "holding \(ordinals)")
        }
        XCTAssertEqual(neverRolled.items(holding: [0]), neverRolled.items())
        XCTAssertEqual(neverRolled.items(holding: [1]), neverRolled.items())
        XCTAssertEqual(rolled.items(holding: [1, 2]), rolled.items(holding: [1]), "the latest message is ignored")
    }

    func testHoldingNothingIsThePlan() {
        XCTAssertEqual(planner(heldBlocks).items(holding: []), planner(heldBlocks).items())
        XCTAssertEqual(planner([]).items(holding: [0]), [])
    }

    func testHoldingDoesNotChangeThePlannerOrRerunIt() {
        var p = planner(heldBlocks)
        let before = p.items()

        _ = p.items(holding: [0, 1])
        _ = p.items(holding: [1])

        XCTAssertEqual(p.items(), before)
        XCTAssertEqual(p.blockCount, heldBlocks.count)
        // The planner keeps working afterwards, as if nothing had been held.
        var rig = Rig()
        rig.feed(heldBlocks)
        _ = p.feed(prose)
        rig.feed(prose)
        XCTAssertEqual(p.items(), rig.items)
        XCTAssertEqual(p.items(holding: [1]), rig.planner.items(holding: [1]))
    }

    // MARK: - Planner cost is linear in segment size

    /// One turn of `n` rolled-in messages and no boundary: (prose, call, result) `n` times, then
    /// a last message. One activity segment of `2n` members (message, group, ...) plus the
    /// latest message (ordinal `n`).
    private func oneLongTurn(_ n: Int) -> [FoldBlock] {
        (0 ..< n).flatMap { [prose, call(id: "c\($0)"), result("c\($0)")] } + [prose]
    }

    /// The base address and member count of the first activity segment a `.rollIn` carries, as
    /// plain numbers. Takes the ops and lets go of them before it returns, so the planner is the
    /// only holder of the segment's storage when the next block is fed (a retained op
    /// legitimately shares the buffer).
    private func feedAndProbeRollIn(_ planner: inout FocusPlanner, _ block: FoldBlock) -> (address: Int, count: Int)? {
        let ops = planner.feed(block)
        for case .rollIn(_, let rolled) in ops {
            for case .activity(let segment) in rolled {
                let address = segment.members.withUnsafeBufferPointer { Int(bitPattern: $0.baseAddress) }
                return (address, segment.members.count)
            }
        }
        return nil
    }

    /// Feeds the turn one block at a time, discarding the ops, and reports the work: elements
    /// the planner visited, and members it copied (a roll-in whose segment storage moved counts
    /// the segment's size: amortized in-place growth sums to about twice the final size, a copy
    /// per roll-in sums to about n squared over two).
    private func feedingCost(_ blocks: [FoldBlock]) -> (visits: Int, copied: Int, rollIns: Int) {
        var planner = FocusPlanner(turnKey: "T")
        var lastAddress: Int?
        var copied = 0
        var rollIns = 0
        for block in blocks {
            if let probe = feedAndProbeRollIn(&planner, block) {
                rollIns += 1
                if probe.address != lastAddress { copied += probe.count }
                lastAddress = probe.address
            }
        }
        return (planner.meter.visits, copied, rollIns)
    }

    private func finishedPlanner(_ blocks: [FoldBlock]) -> FocusPlanner {
        var planner = FocusPlanner(turnKey: "T")
        for block in blocks { _ = planner.feed(block) }
        return planner
    }

    func testFeedingOneLongTurnDoesWorkLinearInItsLength() {
        let small = feedingCost(oneLongTurn(500))
        let large = feedingCost(oneLongTurn(2_000))

        XCTAssertEqual(small.rollIns, 500)
        XCTAssertEqual(large.rollIns, 2_000)
        XCTAssertLessThanOrEqual(large.visits, 5 * small.visits,
                                 "4x the messages must be about 4x the work, not 16x: \(small.visits) -> \(large.visits)")
    }

    func testRollingInOntoABigRowDoesNotCopyTheRowEveryTime() {
        let small = feedingCost(oneLongTurn(500))
        let large = feedingCost(oneLongTurn(2_000))

        XCTAssertGreaterThan(small.copied, 0)
        XCTAssertLessThanOrEqual(large.copied, 5 * small.copied,
                                 "members copied while growing the row: \(small.copied) -> \(large.copied)")
    }

    func testReadingThePlanOfOneLongTurnDoesWorkLinearInItsLengthAndIsRight() {
        func read(_ n: Int) -> Int {
            let planner = finishedPlanner(oneLongTurn(n))
            let before = planner.meter.visits
            let items = planner.items()
            let work = planner.meter.visits - before

            XCTAssertEqual(items.count, 2, "n = \(n)")
            guard case .activity(let row)? = items.first else { XCTFail("expected a row first, got \(items)"); return work }
            XCTAssertEqual(row.members.count, 2 * n, "n = \(n)")
            XCTAssertEqual(row.messageCount, n, "n = \(n)")
            XCTAssertEqual(row.key, "a:m:T#0", "n = \(n)")
            XCTAssertEqual(latest(items)?.ordinal, n, "n = \(n)")
            return work
        }

        let small = read(500)
        let large = read(2_000)

        XCTAssertLessThanOrEqual(large, 5 * small, "items(): \(small) -> \(large)")
    }

    func testReadingThePlanWithAMessageHeldDoesWorkLinearInTheTurnAndIsRight() {
        func read(_ n: Int) -> Int {
            let planner = finishedPlanner(oneLongTurn(n))
            let before = planner.meter.visits
            let held = planner.items(holding: [3])
            let work = planner.meter.visits - before

            // Row of m0 g0 m1 g1 m2 g2, the held m3, the rest as a row keyed by its first member (g3), the latest.
            XCTAssertEqual(held.count, 4, "n = \(n)")
            let rows = segments(held)
            XCTAssertEqual(rows.map(\.members.count), [6, 2 * n - 7], "n = \(n)")
            XCTAssertEqual(rows.map(\.key), ["a:m:T#0", "a:g:c3"], "n = \(n)")
            guard held.count == 4, case .message(let heldMessage) = held[1] else { XCTFail("expected the held message second, got \(held.count) items"); return work }
            XCTAssertEqual(heldMessage.ordinal, 3, "n = \(n)")
            XCTAssertEqual(latest(Array(held.suffix(1)))?.ordinal, n, "n = \(n)")
            return work
        }

        let small = read(500)
        let large = read(2_000)

        XCTAssertLessThanOrEqual(large, 5 * small, "items(holding:): \(small) -> \(large)")
    }

    func testARollInOntoABigRowIsOneRollInThatExtendsTheSameRowByTheNewMessageAndTheTrailingGroup() throws {
        var rig = Rig()
        rig.feed(oneLongTurn(50))
        rig.feed([call(id: "x"), result("x")])
        let before = try XCTUnwrap(segments(rig.items).first)
        XCTAssertEqual(before.members.count, 100)
        XCTAssertEqual(shape(rig.items).count, 3, "row, latest message m50, trailing group: \(shape(rig.items))")

        let ops = rig.feed(prose)

        XCTAssertEqual(kinds(nonGroupOps(ops)), ["rollIn", "latest"])
        guard case .rollIn(let from, let rolled) = nonGroupOps(ops)[0] else { return XCTFail("\(ops)") }
        XCTAssertEqual(from, 0)
        XCTAssertEqual(rolled.count, 1)
        guard case .activity(let row)? = rolled.first else { return XCTFail("expected the row, got \(rolled)") }
        XCTAssertEqual(row.key, before.key)
        XCTAssertEqual(row.members.count, 102)
        XCTAssertEqual(Array(row.members.prefix(100)), before.members)
        guard case .message(let absorbed) = row.members[100], case .group(let trailing) = row.members[101] else {
            return XCTFail("expected the old latest message and the trailing group last: \(row.members.suffix(2))")
        }
        XCTAssertEqual(absorbed.ordinal, 50)
        XCTAssertEqual(trailing.key, "g:x")
        XCTAssertTrue(row.isLive)
        XCTAssertEqual(shape(rig.items), ["act[" + (0 ... 50).map { "m\($0),g\($0)" }.joined(separator: ",") + "]", "msg51"])
    }

    // MARK: - Orphan subagent prose

    /// Non-empty subagent prose that TF2 cannot attach to an Agent/Task call (no Agent call, an
    /// unknown parent, or the Agent already finished) is rendered by TF2 as itself. Like an
    /// orphaned result it is a boundary item: it splits the open message, is never a message
    /// and never part of an activity row, and is never dropped. Whitespace-only subagent prose
    /// has nothing to lose and stays invisible.
    func testSubagentProseThatTF2CannotAttachIsABoundaryThatSplitsTheMessageAndIsNeverDropped() {
        let table: [(String, [FoldBlock], [String])] = [
            ("alone", [subProse("x")], ["b0"]),
            ("alone, parent unknown", [subProse("?")], ["b0"]),
            ("after a group of plain calls", [call(id: "a"), result("a"), subProse("?")], ["grp0", "b2"]),
            ("after a group, parent named but not an Agent call", [call(id: "a"), result("a"), subProse("a")], ["grp0", "b2"]),
            ("while a plain call is open", [call(id: "a"), subProse("a")], ["grp0", "b1"]),
            ("after a finished Agent call", [call("Agent", id: "a"), result("a"), subProse("?")], ["grp0", "b2"]),
            ("after a finished Agent call, parent unknown by id", [call("Agent", id: "a"), result("a"), subProse("nope")], ["grp0", "b2"]),
            ("after the group was closed by text", [call("Agent", id: "a"), result("a"), prose, subProse("?")], ["act[g0]", "msg0", "b3"]),
            ("trailing text, then orphan", [prose, subProse("?")], ["msg0", "b1"]),
            ("between two groups", [call(id: "a"), result("a"), subProse("?"), call(id: "b"), result("b")], ["grp0", "b2", "grp1"]),
            ("between two messages", [prose, subProse("?"), prose], ["act[m0]", "b1", "msg1"]),
            ("a hidden block before it", [prose, .hidden, subProse("?"), prose], ["act[m0]", "b2", "msg1"]),
            ("whitespace before it", [prose, blank, subProse("?"), prose], ["act[m0]", "b2", "msg1"]),
            ("around a group", [prose, call(id: "a"), result("a"), subProse("?"), prose], ["act[m0,g0]", "b3", "msg1"]),
            ("two in a row", [prose, subProse("?"), subProse("x"), prose], ["act[m0]", "b1", "b2", "msg1"]),
            ("with a card between messages", [prose, subProse("?"), card, prose], ["act[m0]", "b1", "b2", "msg1"]),
        ]
        for (name, blocks, expected) in table {
            for outcome: FoldOutcome in [.open, .completedOk, .interrupted] {
                XCTAssertEqual(shape(plan(blocks, outcome)), expected, "\(name), \(outcome)")
            }
        }
    }

    func testAnOrphanSubagentProseIsNeverInAMessageOrARowAsAMember() {
        let blocks: [FoldBlock] = [prose, subProse("?"), prose, call(id: "a"), result("a"), subProse("?"), prose, subProse("x")]

        let items = plan(blocks)

        for message in messageRefs(items) {
            XCTAssertTrue(Set(message.blockIndices).isDisjoint(with: [1, 5, 7]), "message \(message.ordinal): \(message.blockIndices)")
        }
        let boundaries = items.compactMap { item -> Int? in if case .boundary(let i) = item { return i } else { return nil } }
        XCTAssertEqual(boundaries, [1, 5, 7])
    }

    func testWhitespaceOnlySubagentProseStaysInvisibleAndDoesNotSplitAMessage() {
        XCTAssertEqual(plan([subProse("x", nonEmpty: false)]), [])
        XCTAssertEqual(plan([subProse("?", nonEmpty: false), subProse("x", nonEmpty: false)]), [])
        XCTAssertEqual(shape(plan([prose, subProse("?", nonEmpty: false)])), ["msg0"])
        XCTAssertEqual(shape(plan([subProse("?", nonEmpty: false), prose])), ["msg0"])
        XCTAssertEqual(shape(plan([call(id: "a"), result("a"), subProse("?", nonEmpty: false), prose])), ["act[g0]", "msg0"])
        XCTAssertEqual(shape(plan([call(id: "a"), result("a"), prose, subProse("?", nonEmpty: false)])), ["act[g0]", "msg0"])

        let joined = plan([prose, subProse("?", nonEmpty: false), prose])
        XCTAssertEqual(shape(joined), ["msg0"], "it does not split the message")
        XCTAssertEqual(latest(joined)?.blockIndices.first, 0)
        XCTAssertEqual(latest(joined)?.blockIndices.last, 2)
    }

    func testSubagentProseTF2AttachesToAnAgentCallStillRendersInsideTheCallAndLeavesNoItem() {
        // Attached by the call's id, even though the Agent call has finished.
        var blocks: [FoldBlock] = [call("Agent", id: "a"), result("a"), prose, subProse("a"), prose]
        XCTAssertEqual(shape(plan(blocks)), ["act[g0]", "msg0"])
        // Attached to the open group's unfinished Agent call, whatever its parent says.
        blocks = [call("Agent", id: "a"), subProse("?"), subProse("zzz"), result("a"), prose]
        XCTAssertEqual(shape(plan(blocks)), ["act[g0]", "msg0"])
        blocks = [prose, call("Task", id: "t"), subProse("?"), result("t"), prose]
        XCTAssertEqual(shape(plan(blocks)), ["act[m0,g0]", "msg1"])
    }

    func testAnOrphanSubagentProseIsAppendedAsExactlyOneBoundaryItemAndSplitsTheOpenMessage() {
        var rig = Rig()
        rig.feed([prose] + tools("a") + [prose])
        XCTAssertEqual(shape(rig.items), ["act[m0,g0]", "msg1"])

        let orphanOps = rig.feed(subProse("?"))

        XCTAssertEqual(nonGroupOps(orphanOps), [.item(.boundary(4))])
        XCTAssertEqual(shape(rig.items), ["act[m0,g0]", "msg1", "b4"])

        let next = rig.feed(prose)

        XCTAssertEqual(kinds(nonGroupOps(next)), ["rollIn", "latest"], "text after the orphan is a new message")
        XCTAssertEqual(shape(rig.items), ["act[m0,g0,m1]", "b4", "msg2"])
    }

    func testAnOrphanSubagentProseBeforeAnyMessageIsJustABoundaryItem() {
        var rig = Rig()

        XCTAssertEqual(nonGroupOps(rig.feed(subProse("x"))), [.item(.boundary(0))])
        XCTAssertEqual(kinds(nonGroupOps(rig.feed(prose))), ["latest"])
        XCTAssertEqual(shape(rig.items), ["b0", "msg0"])
    }

    func testAnAttachedAndAWhitespaceOnlySubagentProseEmitNothingBesidesGroupUpdates() {
        var rig = Rig()
        rig.feed([prose, call("Agent", id: "a")])

        XCTAssertEqual(nonGroupOps(rig.feed(subProse("a"))), [])
        XCTAssertEqual(nonGroupOps(rig.feed(subProse("?"))), [])
        XCTAssertEqual(nonGroupOps(rig.feed(subProse("?", nonEmpty: false))), [])
        XCTAssertEqual(shape(rig.items), ["msg0", "grp0"])
    }

    func testAnOrphanSubagentProseSitsAtItsChronologicalPlaceWhileAMessageIsHeld() {
        // m0 g0 m1 [orphan] m2 g1 m3: rows [m0,g0,m1] and [m2,g1], the latest m3.
        let blocks: [FoldBlock] = [prose] + tools("a") + [prose, subProse("?"), prose] + tools("b") + [prose]
        let p = planner(blocks)
        XCTAssertEqual(shape(p.items()), ["act[m0,g0,m1]", "b4", "act[m2,g1]", "msg3"])

        XCTAssertEqual(shape(p.items(holding: [1])), ["act[m0,g0]", "msg1", "b4", "act[m2,g1]", "msg3"])
        XCTAssertEqual(shape(p.items(holding: [2])), ["act[m0,g0,m1]", "b4", "msg2", "grp1", "msg3"])
        XCTAssertEqual(shape(p.items(holding: [0, 1, 2])), ["msg0", "grp0", "msg1", "b4", "msg2", "grp1", "msg3"])
        for held: Set<Int> in [[], [0], [1], [2], [0, 2], [1, 2]] {
            XCTAssertEqual(atoms(p.items(holding: held)), atoms(p.items()), "holding \(held.sorted())")
        }
    }

    func testTheGeneratorKeepsProducingBothAttachedAndOrphanSubagentProse() {
        // Guards the property test: it must keep exercising both outcomes of TF2's attachment.
        var attached = 0
        var orphans = 0
        for n in 0 ..< 400 {
            var rng = FocusSplitMix64(seed: UInt64(n) &* 104_729 &+ 7)
            var tf2 = ToolFoldPlanner(turnKey: "turn-\(n)")
            for case .block(let block, _) in randomSteps(&rng) {
                let index = tf2.blockCount
                let ops = tf2.feed(block)
                guard case .prose(true, _?) = block else { continue }
                if ops.contains(.block(index)) { orphans += 1 } else { attached += 1 }
            }
        }
        XCTAssertGreaterThan(orphans, 100)
        XCTAssertGreaterThan(attached, 100)
    }

    // MARK: - Property: replaying the ops is the batch plan

    private enum Category {
        case message, transparent, toolOrResult, subagentToolOrResult, boundary
        /// Non-empty subagent prose: attached to an Agent call it is transparent, otherwise
        /// (TF2 renders it as itself) it is a boundary. Decided at run time, from TF2.
        case subagentProse
    }

    private enum Step {
        case block(FoldBlock, Category)
        case quiet(String, Double?)
    }

    private func pr() -> Step { .block(prose, .message) }
    private func ws() -> Step { .block(blank, .transparent) }
    private func hid() -> Step { .block(.hidden, .transparent) }
    private func sub(_ parent: String) -> Step { .block(.prose(nonEmpty: true, parentId: parent), .subagentProse) }
    private func subBlank(_ parent: String) -> Step { .block(.prose(nonEmpty: false, parentId: parent), .transparent) }
    private func cl(_ id: String?, _ name: String = "Bash", started: Double? = nil) -> Step {
        .block(call(name, id: id, started: started), .toolOrResult)
    }
    private func rs(_ id: String?, error: Bool = false, at seconds: Double? = nil) -> Step {
        .block(result(id, error: error, at: seconds), .toolOrResult)
    }
    private func subCall(_ id: String, parent: String) -> Step { .block(call(id: id, parent: parent), .subagentToolOrResult) }
    private func subResult(_ id: String, parent: String, error: Bool = false) -> Step {
        .block(result(id, parent: parent, error: error), .subagentToolOrResult)
    }
    private func bnd(_ kind: FoldBoundaryKind) -> Step { .block(.boundary(kind), .boundary) }
    private func qf(_ id: String, at seconds: Double? = nil) -> Step { .quiet(id, seconds) }

    /// The blocks a batch caller passes for steps so far: quiet finishes folded into their calls.
    private func batchBlocks(_ steps: ArraySlice<Step>) -> [FoldBlock] {
        var blocks: [FoldBlock] = []
        var finishes: [String: Double?] = [:]
        for step in steps {
            switch step {
            case .block(let block, _): blocks.append(block)
            case .quiet(let id, let seconds): finishes[id] = .some(seconds)
            }
        }
        return blocks.map { block in
            guard case .toolCall(var c) = block, let id = c.toolUseId, let finish = finishes[id] else { return block }
            c.finishedAt = finish.map(at)
            c.finishedQuietly = true
            return .toolCall(c)
        }
    }

    /// Feeds `steps` one at a time and checks, after each step and after every kind of ending,
    /// that replaying all ops so far is the batch plan of the blocks so far; and that the ops
    /// obey the emission rules.
    private func assertOpsReplayToThePlan(_ steps: [Step], turnKey: String, _ name: String,
                                          file: StaticString = #filePath, line: UInt = #line) {
        var planner = FocusPlanner(turnKey: turnKey)
        var allOps: [FocusOp] = []
        // Does the latest message still accept text (nothing has split it since)?
        var messageOpen = false

        for (n, step) in steps.enumerated() {
            let context = "\(name), step \(n)"
            let before = planner.items()
            let ops: [FocusOp]
            switch step {
            case .block(let block, let declared):
                ops = planner.feed(block)
                let index = planner.blockCount - 1
                var category = declared
                if declared == .subagentProse {
                    // Attached to an Agent call it renders inside the call; with nowhere to attach
                    // TF2 renders it as itself and it is a boundary item.
                    let attached = allGroups(planner.items()).contains { $0.subagentBlocks.values.joined().contains(index) }
                    category = attached ? .transparent : .boundary
                    if !attached {
                        XCTAssertEqual(nonGroupOps(ops), [.item(.boundary(index))],
                                       "an orphan subagent prose is exactly one boundary item: \(context)", file: file, line: line)
                    }
                }
                assertEmission(ops, category: category, before: before, messageOpen: messageOpen, context, file: file, line: line)
                switch category {
                case .message: messageOpen = true
                case .toolOrResult, .boundary: messageOpen = false
                case .subagentToolOrResult:
                    // Attached to an Agent call, a subagent's block is transparent; with nowhere
                    // to attach TF2 treats it as a top-level call or result, which splits.
                    let index = planner.blockCount - 1
                    let attached = allGroups(planner.items()).contains { $0.subagentBlocks.values.joined().contains(index) }
                    if !attached { messageOpen = false }
                case .transparent: break
                case .subagentProse: XCTFail("resolved above: \(context)", file: file, line: line)
                }
            case .quiet(let id, let seconds):
                ops = planner.callFinished(toolUseId: id, at: seconds.map(at))
                XCTAssertTrue(ops.allSatisfy(isGroupChanged), "a quiet finish only updates a group: \(context): \(ops)", file: file, line: line)
            }
            allOps += ops

            let blocks = batchBlocks(steps.prefix(n + 1))
            let batch = plan(blocks, .open, key: turnKey)
            XCTAssertEqual(FocusPlanner.replay(allOps), batch, "replay vs plan: \(context)", file: file, line: line)
            XCTAssertEqual(planner.items(), batch, "items() vs plan: \(context)", file: file, line: line)
            assertWellFormed(batch, blocks: blocks, outcome: .open, turnKey: turnKey, context, file: file, line: line)
        }

        let blocks = batchBlocks(steps[...])
        XCTAssertEqual(planner.blockCount, steps.filter { if case .block = $0 { return true } else { return false } }.count, name, file: file, line: line)
        for outcome: FoldOutcome in [.completedOk, .completedError, .interrupted, .errored] {
            let context = "\(name), ended \(outcome)"
            var ended = planner
            let endOps = ended.turnEnded(outcome: outcome)
            XCTAssertTrue(endOps.allSatisfy { op in
                switch op {
                case .groupChanged, .segmentChanged: return true
                default: return false
                }
            }, "ending only updates groups and the live row: \(context): \(endOps)", file: file, line: line)
            XCTAssertLessThanOrEqual(endOps.filter { if case .segmentChanged = $0 { return true } else { return false } }.count, 1, context, file: file, line: line)

            let batch = plan(blocks, outcome, key: turnKey)
            XCTAssertEqual(FocusPlanner.replay(allOps + endOps), batch, "replay vs plan: \(context)", file: file, line: line)
            XCTAssertEqual(ended.items(), batch, "items() vs plan: \(context)", file: file, line: line)
            assertWellFormed(batch, blocks: blocks, outcome: outcome, turnKey: turnKey, context, file: file, line: line)
        }
    }

    /// What one fed block may emit (contract §2.1 "Emission").
    private func assertEmission(_ ops: [FocusOp], category: Category, before: [FocusItem], messageOpen: Bool,
                                _ context: String, file: StaticString, line: UInt) {
        let main = nonGroupOps(ops)
        XCTAssertLessThanOrEqual(main.count, 3, "op count: \(context): \(ops)", file: file, line: line)
        XCTAssertLessThanOrEqual(kinds(main).filter { $0 == "rollIn" }.count, 1, context, file: file, line: line)
        XCTAssertLessThanOrEqual(kinds(main).filter { $0 == "latest" }.count, 1, context, file: file, line: line)

        switch category {
        case .transparent:
            XCTAssertEqual(main, [], "a transparent block emits only group updates: \(context)", file: file, line: line)
        case .subagentProse:
            XCTFail("a subagent prose is resolved to transparent or boundary before it is checked: \(context)", file: file, line: line)
        case .toolOrResult, .subagentToolOrResult, .boundary:
            XCTAssertTrue(main.allSatisfy { if case .item = $0 { return true } else { return false } },
                          "a call, result or boundary never touches the latest message or a row: \(context): \(main)", file: file, line: line)
            XCTAssertLessThanOrEqual(main.count, 1, context, file: file, line: line)
        case .message:
            XCTAssertFalse(kinds(main).contains("item"), "a message appends through latestChanged: \(context): \(main)", file: file, line: line)
            guard case .latestChanged(let newest)? = main.last else {
                return XCTFail("a message ends with latestChanged: \(context): \(main)", file: file, line: line)
            }
            for case .rollIn(_, let rolled) in main {
                XCTAssertFalse(rolled.contains(.message(newest)), "the roll-in carries the new latest message: \(context)", file: file, line: line)
            }
            let rollIns = kinds(main).filter { $0 == "rollIn" }.count
            let hadMessageOrGroup = before.contains { item in
                switch item {
                case .message, .group: return true
                default: return false
                }
            }
            if messageOpen {
                XCTAssertEqual(rollIns, 0, "text that continues the latest message never rolls in: \(context)", file: file, line: line)
                XCTAssertEqual(main.count, 1, context, file: file, line: line)
                XCTAssertEqual(newest.ordinal, latest(before)?.ordinal, context, file: file, line: line)
            } else {
                XCTAssertEqual(rollIns, hadMessageOrGroup ? 1 : 0,
                               "a new message rolls in exactly when there is a latest message or a trailing group: \(context)", file: file, line: line)
                XCTAssertEqual(newest.ordinal, (latest(before)?.ordinal ?? -1) + 1, context, file: file, line: line)
            }
        }
    }

    /// The invariants of any Focus layout of `blocks`.
    private func assertWellFormed(_ items: [FocusItem], blocks: [FoldBlock], outcome: FoldOutcome, turnKey: String,
                                  _ context: String, file: StaticString, line: UInt) {
        var messages: [MessageRef] = []
        var firsts: [Int] = []
        var groups: [ToolGroup] = []
        var boundaries: [Int] = []
        var rowKeys: [String] = []
        var messageItems = 0
        var seenLatestItem = false
        var previousWasRow = false

        func firstIndex(_ m: MessageRef) -> Int { m.blockIndices.first ?? -1 }
        func firstIndex(_ g: ToolGroup) -> Int { g.memberIndices.first ?? -1 }

        for item in items {
            switch item {
            case .activity(let s):
                XCTAssertFalse(seenLatestItem, "a row after the latest message: \(context)", file: file, line: line)
                XCTAssertFalse(previousWasRow, "two rows with no boundary between them: \(context)", file: file, line: line)
                XCTAssertFalse(s.members.isEmpty, context, file: file, line: line)
                rowKeys.append(s.key)
                switch s.members.first {
                case .message(let m)?: XCTAssertEqual(s.key, "a:m:\(turnKey)#\(m.ordinal)", context, file: file, line: line)
                case .group(let g)?: XCTAssertEqual(s.key, "a:" + g.key, context, file: file, line: line)
                case nil: break
                }
                for member in s.members {
                    switch member {
                    case .message(let m): messages.append(m); firsts.append(firstIndex(m))
                    case .group(let g): groups.append(g); firsts.append(firstIndex(g))
                    }
                }
            case .message(let m):
                messageItems += 1
                XCTAssertFalse(seenLatestItem, "two latest messages: \(context)", file: file, line: line)
                seenLatestItem = true
                messages.append(m)
                firsts.append(firstIndex(m))
            case .boundary(let i):
                boundaries.append(i)
                firsts.append(i)
            case .group(let g):
                groups.append(g)
                firsts.append(firstIndex(g))
            }
            if case .activity = item { previousWasRow = true } else { previousWasRow = false }
        }

        // Groups beside the latest message come after it, and are the planner's own groups.
        if let latestAt = items.firstIndex(where: { if case .message = $0 { return true } else { return false } }) {
            for (n, item) in items.enumerated() {
                if case .group = item { XCTAssertGreaterThan(n, latestAt, "a trailing group above the latest message: \(context)", file: file, line: line) }
            }
        }
        let tf2 = ToolFoldPlanner.plan(blocks: blocks, outcome: outcome, turnKey: turnKey)
        let tf2Groups = tf2.compactMap { item -> ToolGroup? in if case .group(let g) = item { return g } else { return nil } }
        XCTAssertEqual(groups, tf2Groups, "groups are TF2's, each exactly once, in order: \(context)", file: file, line: line)
        let tf2Boundaries = tf2.compactMap { item -> Int? in
            guard case .block(let i) = item else { return nil }
            if case .prose(let nonEmpty, let parent) = blocks[i] {
                // Top-level text is a message, whitespace-only prose is invisible; only
                // non-empty subagent prose TF2 could not attach is a boundary.
                return nonEmpty && parent != nil ? i : nil
            }
            return i
        }
        XCTAssertEqual(boundaries, tf2Boundaries, "boundaries are every boundary and orphan, in order: \(context)", file: file, line: line)

        // Messages: ordinals, coverage, shape.
        XCTAssertEqual(messages.map(\.ordinal), Array(0 ..< messages.count), "ordinals: \(context)", file: file, line: line)
        XCTAssertEqual(messageItems, messages.isEmpty ? 0 : 1, "exactly one latest message when there is any message: \(context)", file: file, line: line)
        if let lastMessage = messages.last, let latestItem = latest(items) {
            XCTAssertEqual(latestItem, lastMessage, "the latest message is the last message: \(context)", file: file, line: line)
        }
        var textIndices: [Int] = []
        for (i, block) in blocks.enumerated() {
            if case .prose(true, nil) = block { textIndices.append(i) }
        }
        var covered: [Int] = []
        let attached = Set(tf2Groups.flatMap { $0.subagentBlocks.values.joined() })
        for m in messages {
            XCTAssertEqual(m.blockIndices, m.blockIndices.sorted(), context, file: file, line: line)
            XCTAssertTrue(m.blockIndices.first.map(textIndices.contains) == true, "a message starts with text: \(context)", file: file, line: line)
            XCTAssertTrue(m.blockIndices.last.map(textIndices.contains) == true, "a message ends with text: \(context)", file: file, line: line)
            for i in m.blockIndices {
                if textIndices.contains(i) {
                    covered.append(i)
                } else {
                    switch blocks[i] {
                    case .hidden: break
                    case .prose(let nonEmpty, let parent):
                        XCTAssertFalse(nonEmpty && parent != nil, "subagent prose is never inside a message: \(context)", file: file, line: line)
                    case .toolCall, .toolResult:
                        XCTAssertTrue(attached.contains(i), "a top-level call or result inside a message: \(context)", file: file, line: line)
                    case .boundary: XCTFail("a boundary inside a message: \(context)", file: file, line: line)
                    }
                }
            }
        }
        XCTAssertEqual(covered.sorted(), textIndices, "every top-level text block is in exactly one message: \(context)", file: file, line: line)

        // Chronology and keys.
        XCTAssertEqual(firsts, firsts.sorted(), "items are in block order: \(context)", file: file, line: line)
        XCTAssertEqual(Set(firsts).count, firsts.count, context, file: file, line: line)
        XCTAssertEqual(Set(rowKeys).count, rowKeys.count, "row keys are unique: \(context)", file: file, line: line)
        let rows = items.compactMap { item -> ActivitySegment? in if case .activity(let s) = item { return s } else { return nil } }
        for (n, row) in rows.enumerated() {
            XCTAssertEqual(row.isLive, outcome == .open && n == rows.count - 1, "isLive of row \(n): \(context)", file: file, line: line)
        }
    }

    // Hand-written sequences, so a failure reads as a story.

    func testReplayMatchesThePlanForHandWrittenSequences() {
        let sequences: [(String, [Step])] = [
            ("empty", []),
            ("A", [pr()]),
            ("A, call, B", [pr(), cl("a"), rs("a"), pr()]),
            ("A, card, call, B", [pr(), bnd(.askQuestion), cl("a"), rs("a"), pr()]),
            ("call, A", [cl("a"), rs("a"), pr()]),
            ("call, call, A, call, B", [cl("a"), cl("b"), pr(), cl("c"), pr()]),
            ("A, call, B, call, C, summary", [pr(), cl("a"), rs("a"), pr(), cl("b"), rs("b"), pr(), bnd(.resultSummary)]),
            ("A, hidden, whitespace, B", [pr(), hid(), ws(), pr()]),
            ("A, call, whitespace, B", [pr(), cl("a"), ws(), pr()]),
            ("card, A, card, B", [bnd(.askQuestion), pr(), bnd(.askQuestion), pr()]),
            ("A, orphan result, B", [pr(), rs(nil), pr()]),
            ("A, error, B, note, C", [pr(), bnd(.errorMessage), pr(), bnd(.note), pr()]),
            ("A, call, quiet finish, B", [pr(), cl("a", started: 1), qf("a", at: 4), pr()]),
            ("A, call, B, quiet finish", [pr(), cl("a", started: 1), pr(), qf("a", at: 4)]),
            ("call, quiet finish without a time, A", [cl("a", started: 1), qf("a"), pr()]),
            ("agent with subagent traffic", [cl("a", "Agent"), sub("a"), subCall("s1", parent: "a"), subResult("s1", parent: "a", error: true), rs("a"), pr()]),
            ("A, subagent prose, B", [pr(), sub("?"), pr()]),
            ("A, call, subagent prose with nowhere to go, B", [pr(), cl("a"), rs("a"), sub("?"), pr()]),
            ("A, whitespace-only subagent prose, B", [pr(), subBlank("?"), pr()]),
            ("orphan subagent prose alone", [sub("x")]),
            ("A, orphan subagent prose", [pr(), sub("?")]),
            ("call, orphan subagent prose", [cl("a"), rs("a"), sub("?")]),
            ("A, call, orphan subagent prose, B", [pr(), cl("a"), rs("a"), sub("?"), pr()]),
            ("finished Agent, orphan subagent prose, A", [cl("a", "Agent"), rs("a"), sub("?"), pr()]),
            ("Agent, attached subagent prose, A", [cl("a", "Agent"), sub("a"), sub("?"), rs("a"), pr()]),
            ("A, orphan, orphan, B, card, orphan, C", [pr(), sub("?"), sub("x"), pr(), bnd(.note), sub("?"), pr()]),
            ("call without id, positional result, A", [cl(nil), rs(nil), pr()]),
            ("ten messages", (0 ..< 10).flatMap { [pr(), cl("t\($0)"), rs("t\($0)")] } + [pr()]),
        ]
        for (name, steps) in sequences { assertOpsReplayToThePlan(steps, turnKey: "T", name) }
    }

    func testReplayMatchesThePlanForFourHundredRandomTurnsAtEveryPrefixAndEveryEnding() {
        for n in 0 ..< 400 {
            var rng = FocusSplitMix64(seed: UInt64(n) &* 104_729 &+ 7)
            let steps = randomSteps(&rng)
            assertOpsReplayToThePlan(steps, turnKey: "turn-\(n)", "random sequence \(n) (\(steps.count) steps)")
        }
    }

    func testTheGeneratorsTurnsAreFoldedConsistentlyByToolFoldPlannerItself() {
        // Guards the property test above: if TF2 alone disagreed with itself on these turns,
        // a failure there would not be Focus's.
        for n in 0 ..< 400 {
            var rng = FocusSplitMix64(seed: UInt64(n) &* 104_729 &+ 7)
            let steps = randomSteps(&rng)
            var tf2 = ToolFoldPlanner(turnKey: "turn-\(n)")
            var ops: [ToolFoldPlanner.Op] = []
            var fedSteps = 0
            for step in steps {
                switch step {
                case .block(let block, _): ops += tf2.feed(block)
                case .quiet(let id, let seconds): ops += tf2.callFinished(toolUseId: id, at: seconds.map(at))
                }
                fedSteps += 1
                XCTAssertEqual(tf2.items(), ToolFoldPlanner.plan(blocks: batchBlocks(steps.prefix(fedSteps)), outcome: .open, turnKey: "turn-\(n)"),
                               "sequence \(n), step \(fedSteps)")
            }
            XCTAssertEqual(ToolFoldPlanner.replay(ops), tf2.items(), "sequence \(n)")
        }
    }

    func testHoldingAnySetOfMessagesKeepsEveryItemInOrderAndFoldsOnlyTheMessagesNotHeld() {
        for n in 0 ..< 200 {
            var rng = FocusSplitMix64(seed: UInt64(n) &* 15_485_863 &+ 11)
            let steps = randomSteps(&rng)
            var planner = FocusPlanner(turnKey: "T")
            for case .block(let block, _) in steps { _ = planner.feed(block) }
            let items = planner.items()
            let ordinals = Array(0 ... max(0, (rolledOrdinals(items).max() ?? 0) + 1))
            for trial in 0 ..< 4 {
                let held = Set(ordinals.filter { _ in rng.next() % 2 == 0 })
                let presented = planner.items(holding: held)
                let context = "sequence \(n), holding \(held.sorted()), trial \(trial)"

                XCTAssertEqual(atoms(presented), atoms(items), "same content in the same order: \(context)")
                let rolled = Set(rolledOrdinals(items))
                let released = held.intersection(rolled)
                var topLevelMessages = Set<Int>()
                for case .message(let m) in presented { topLevelMessages.insert(m.ordinal) }
                XCTAssertEqual(topLevelMessages.subtracting(Set(latest(items).map { [$0.ordinal] } ?? [])), released,
                               "exactly the held rolled-in messages stand on their own: \(context)")
                if released.isEmpty { XCTAssertEqual(presented, items, "nothing to hold: \(context)") }
                let keys = presented.compactMap { item -> String? in if case .activity(let s) = item { return s.key } else { return nil } }
                XCTAssertEqual(Set(keys).count, keys.count, "row keys stay unique: \(context)")
                XCTAssertEqual(planner.items(), items, "holding is a view: \(context)")
            }
        }
    }

    private func rolledOrdinals(_ items: [FocusItem]) -> [Int] {
        var out: [Int] = []
        for case .activity(let s) in items {
            for case .message(let m) in s.members { out.append(m.ordinal) }
        }
        return out
    }

    private func atoms(_ items: [FocusItem]) -> [String] {
        var out: [String] = []
        for item in items {
            switch item {
            case .activity(let s):
                for member in s.members {
                    switch member {
                    case .message(let m): out.append("m\(m.ordinal)")
                    case .group(let g): out.append("g\(g.id)")
                    }
                }
            case .message(let m): out.append("m\(m.ordinal)")
            case .boundary(let i): out.append("b\(i)")
            case .group(let g): out.append("g\(g.id)")
            }
        }
        return out
    }

    private func randomSteps(_ rng: inout FocusSplitMix64) -> [Step] {
        let names = ["Bash", "Read", "Edit", "Agent", "Task", "Agent", "Grep", "mcp__srv__tool", "Frobnicate"]
        var serial = 0
        var topLevelCallIds: [String] = []
        var agentIds: [String] = []
        // Calls that may still finish quietly: no result has reached them, or could have by position;
        // never an Agent call.
        var eligible: [String] = []
        var steps: [Step] = []

        func chance(_ percent: UInt64) -> Bool { rng.next() % 100 < percent }
        func pick<T>(_ array: [T]) -> T { array[Int(rng.next() % UInt64(array.count))] }
        func parent() -> String { agentIds.isEmpty || chance(30) ? "?" : pick(agentIds) }
        func time() -> Double? { chance(70) ? Double(serial) : nil }

        for _ in 0 ..< Int(rng.next() % 41) {
            serial += 1
            switch rng.next() % 16 {
            case 0, 1, 2:
                steps.append(pr())
            case 3:
                steps.append(ws())
            case 4:
                steps.append(hid())
            case 5, 6, 7:
                let name = pick(names)
                let id: String? = chance(85) ? "c\(serial)" : nil
                if let id {
                    topLevelCallIds.append(id)
                    if name == "Agent" || name == "Task" {
                        agentIds.append(id)   // an Agent that finished quietly takes no subagent blocks (TF3), so it never finishes late
                    } else {
                        eligible.append(id)
                    }
                }
                steps.append(cl(id, name, started: time()))
            case 8, 9:
                if !topLevelCallIds.isEmpty && chance(70) {
                    let id = pick(topLevelCallIds)
                    eligible.removeAll { $0 == id }
                    steps.append(rs(id, error: chance(25), at: time()))
                } else if chance(50) {
                    eligible.removeAll()   // a result with no id pairs with a call by position
                    steps.append(rs(nil, error: chance(25), at: time()))
                } else {
                    steps.append(rs("ghost\(serial)", error: chance(25), at: time()))
                }
            case 10:
                steps.append(chance(20) ? subBlank(parent()) : sub(parent()))
            case 11:
                steps.append(subCall("s\(serial)", parent: parent()))
            case 12:
                steps.append(subResult("sr\(serial)", parent: parent(), error: chance(25)))
            case 13:
                steps.append(bnd(pick([.askQuestion, .errorMessage, .note, .resultSummary, .other])))
            default:
                if eligible.isEmpty {
                    steps.append(pr())
                } else {
                    let id = pick(eligible)
                    eligible.removeAll { $0 == id }
                    steps.append(qf(id, at: time()))
                }
            }
        }
        return steps
    }
}

/// Deterministic random numbers, so a failing sequence number reproduces.
private struct FocusSplitMix64 {
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
