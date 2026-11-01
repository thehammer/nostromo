import XCTest
import AppKit
import NostromoKit

// TF2 (transcript tool folds), the Mac's side of the fold rule.
//
// `ToolFoldAdapter`, `FoldResolver`, ChatModels and TurnInteractionStore are compiled into this
// logic-test bundle directly; NostromoKit (`ToolFoldPlanner`, `ToolGroup`, `FoldBlock`, ...) is
// linked. The rule itself (what forms a group, the summary grammar) is pinned in NostromoKit's own
// tests; these pin the *adapter*: how a `ChatTurn` becomes fold input, how a turn's end becomes a
// `FoldOutcome`, what the height-cache digest is, and how rows are counted for diagnostics.

// MARK: - Shared fixtures (used by every TF2 Mac test file)

/// Builders shared by the TF2 Mac tests. Internal on purpose: the view, estimator, virtualizer
/// and copy tests all need the same turns. Groups come from NostromoKit's planner directly, not
/// from `ToolFoldAdapter`, so a view test fails only for a view reason.
enum FoldFixtures {

    static let epoch = Date(timeIntervalSince1970: 1_770_000_000)
    static func at(_ seconds: Double) -> Date { epoch.addingTimeInterval(seconds) }

    /// A `Bash` call's `inputFull`, as the daemon sends it (pretty JSON with `command`).
    static func bashInput(_ command: String) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["command": command, "description": "d"],
                                               options: [.prettyPrinted, .sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// A non-Bash call's `inputFull`. Slashes unescaped, as the daemon's serde_json writes them.
    static func jsonInput(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object,
                                               options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    static func call(_ name: String = "Bash", id: String? = nil, summary: String = "echo hi",
                     full: String? = nil, parent: String? = nil, target: String? = nil,
                     start: Double? = nil, finish: Double? = nil) -> TurnBlock {
        let input = full ?? (name == "Bash" ? bashInput(summary) : jsonInput(["file_path": summary]))
        return .toolCall(ToolCallData(toolName: name, inputSummary: summary, inputFull: input,
                                      toolUseId: id, parentToolUseId: parent, target: target,
                                      startedAt: start.map(at), finishedAt: finish.map(at)))
    }

    static func result(_ content: String = "ok", id: String? = nil, isError: Bool = false,
                       parent: String? = nil, time: Double? = nil) -> TurnBlock {
        .toolResult(ToolResultData(content: content, isError: isError, toolUseId: id,
                                   parentToolUseId: parent, at: time.map(at)))
    }

    static func question() -> TurnBlock {
        .askQuestion(AskQuestionData(question: "Ship it?", header: "Decision",
                                     options: [AskQuestionData.Option(label: "Yes", description: "merge"),
                                               AskQuestionData.Option(label: "No", description: "hold")],
                                     multiSelect: false))
    }

    static func chip() -> TurnBlock {
        .resultSummary(ResultSummaryData(durationMs: 5, costUSD: 0.01, isError: false))
    }

    /// `n` calls, each followed by its result: ids `<prefix>0`..., summaries `cmd <prefix>0`...
    static func run(_ n: Int, prefix: String = "t", name: String = "Bash",
                    output: (Int) -> String = { "output \($0)" }) -> [TurnBlock] {
        (0 ..< n).flatMap { i in
            [call(name, id: "\(prefix)\(i)", summary: "cmd \(prefix)\(i)"),
             result(output(i), id: "\(prefix)\(i)")]
        }
    }

    static let prose = "A paragraph of plain assistant prose with no markdown markers in it."

    static func turn(_ blocks: [TurnBlock], complete: Bool = true, user: String = "hi",
                     raw: String? = "2026-10-13T00:00:00.000Z",
                     textParents: [Int: String] = [:]) -> ChatTurn {
        ChatTurn(userInput: user, timestamp: epoch, timestampRaw: raw, blocks: blocks,
                 isComplete: complete, daemonId: "t0", epoch: 0, subagentTextParents: textParents)
    }

    // MARK: Oracle (the PRD mapping, restated so view tests do not depend on the adapter)

    static func foldBlock(_ block: TurnBlock, at index: Int, in turn: ChatTurn) -> FoldBlock {
        switch block {
        case .text(let s):
            return .prose(nonEmpty: s.contains { !$0.isWhitespace }, parentId: turn.subagentTextParents[index])
        case .toolCall(let d):
            return .toolCall(FoldCall(name: d.toolName, toolUseId: d.toolUseId, parentId: d.parentToolUseId,
                                      target: d.target, startedAt: d.startedAt, finishedAt: d.finishedAt,
                                      inputSummary: d.inputSummary, inputFull: d.inputFull))
        case .toolResult(let d):
            return .toolResult(FoldResult(toolUseId: d.toolUseId, parentId: d.parentToolUseId,
                                          isError: d.isError, at: d.at))
        case .resultSummary: return .boundary(.resultSummary)
        case .errorMessage:  return .boundary(.errorMessage)
        case .askQuestion:   return .boundary(.askQuestion)
        case .note:          return .boundary(.note)
        }
    }

    static func outcome(of turn: ChatTurn) -> FoldOutcome {
        guard turn.isComplete else { return .open }
        var errored = false
        for block in turn.blocks {
            switch block {
            case .resultSummary(let d):
                if d.interrupted { return .interrupted }
                if d.isError { return .completedError }
            case .errorMessage: errored = true
            default: break
            }
        }
        return errored ? .errored : .completedOk
    }

    /// The turn's groups, from NostromoKit's planner.
    static func groups(of turn: ChatTurn) -> [ToolGroup] {
        let blocks = turn.blocks.enumerated().map { foldBlock($1, at: $0, in: turn) }
        return ToolFoldPlanner.plan(blocks: blocks, outcome: outcome(of: turn), turnKey: turn.identityKey)
            .compactMap { if case .group(let g) = $0 { return g } else { return nil } }
    }

    /// A group of calls straight from fold blocks (row tests need no turn).
    static func group(_ blocks: [FoldBlock], outcome: FoldOutcome = .completedOk,
                      turnKey: String = "turn-key") -> ToolGroup {
        for item in ToolFoldPlanner.plan(blocks: blocks, outcome: outcome, turnKey: turnKey) {
            if case .group(let g) = item { return g }
        }
        fatalError("fixture has no group")
    }

    static func foldCall(_ name: String, id: String, summary: String = "", full: String = "",
                         target: String? = nil, start: Double? = nil) -> FoldBlock {
        .toolCall(FoldCall(name: name, toolUseId: id, target: target, startedAt: start.map(at),
                           inputSummary: summary, inputFull: full))
    }

    static func foldResult(id: String, isError: Bool = false, time: Double? = nil) -> FoldBlock {
        .toolResult(FoldResult(toolUseId: id, isError: isError, at: time.map(at)))
    }

    /// `n` Bash calls, the last one failing, from t=0 to t=4.1 s: summary, badge and time all show.
    static func failingGroup(calls n: Int = 3) -> ToolGroup {
        var blocks: [FoldBlock] = []
        for i in 0 ..< n {
            let last = i == n - 1
            blocks.append(foldCall("Bash", id: "f\(i)", summary: "make step\(i)",
                                   full: bashInput("make step\(i)"), start: Double(i)))
            blocks.append(foldResult(id: "f\(i)", isError: last, time: last ? 4.1 : Double(i) + 0.5))
        }
        return group(blocks)
    }

    /// A group with no failure and no known time.
    static func plainGroup(calls n: Int, name: String = "Bash") -> ToolGroup {
        var blocks: [FoldBlock] = []
        for i in 0 ..< n {
            blocks.append(foldCall(name, id: "p\(i)", summary: "cmd \(i)", full: bashInput("cmd \(i)")))
            blocks.append(foldResult(id: "p\(i)"))
        }
        return group(blocks)
    }

    // MARK: Hostile strings (copied from NostromoKit's HostileContent, which the Mac target cannot see)

    static let longCommand = "echo " + String(repeating: "x", count: 9_995)
    static let hostileSummary = "run\u{1B}[31mred\u{1B}[0m\nnext line \u{202E}evil\u{2066}x\u{2069}\u{E0041}tail\r\u{7}"
    static let megabyte = String(repeating: "0123456789abcde\n", count: 65_536)

    static func isForbiddenOnARow(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0000 ... 0x001F, 0x007F, 0x0080 ... 0x009F,
             0x200E, 0x200F, 0x202A ... 0x202E, 0x2066 ... 0x2069, 0xE0000 ... 0xE007F:
            return true
        default:
            return false
        }
    }

    // MARK: The benchmark session, as the app maps it

    /// The generator's session decoded through the Mac's wire decoder and mapped to `ChatTurn`s
    /// the way `ChatSession.mapTurn` does (that mapping is private, so it is restated here).
    static func benchmarkTurns() throws -> [ChatTurn] {
        let data = BenchmarkTranscript.sessionTurnsJSON(emptyResults: false)
        return try JSONDecoder().decode([DaemonTurn].self, from: data).map(mapTurn)
    }

    private static func mapTurn(_ t: DaemonTurn) -> ChatTurn {
        var blocks: [TurnBlock] = []
        var parents: [Int: String] = [:]
        for wire in t.blocks {
            let index = blocks.count
            if ToolCompletionFolding.apply(mapBlock(wire), to: &blocks), let parent = wire.textParent {
                parents[index] = parent
            }
        }
        return ChatTurn(userInput: t.userInput, timestamp: epoch, timestampRaw: t.timestamp, blocks: blocks,
                        isComplete: t.isComplete, daemonId: t.id, epoch: 0, subagentTextParents: parents)
    }

    private static func mapBlock(_ b: DaemonTurnBlock) -> TurnBlock {
        switch b {
        case .text(let s, _):
            return .text(s)
        case .toolCall(let name, let summary, let full, let meta):
            return .toolCall(ToolCallData(toolName: name, inputSummary: summary, inputFull: full,
                                          toolUseId: meta.toolUseId, parentToolUseId: meta.parentToolUseId,
                                          target: meta.target, startedAt: meta.ts))
        case .toolResult(let content, let isError, let meta):
            return .toolResult(ToolResultData(content: content, isError: isError, toolUseId: meta.toolUseId,
                                              parentToolUseId: meta.parentToolUseId, at: meta.ts))
        case .resultSummary(let d, let c, let e, let i):
            return .resultSummary(ResultSummaryData(durationMs: d, costUSD: c, isError: e, interrupted: i))
        case .errorMessage(let m):
            return .errorMessage(m)
        case .askQuestion(let q, let h, let opts, let multi):
            return .askQuestion(AskQuestionData(
                question: q, header: h,
                options: opts.map { AskQuestionData.Option(label: $0.label, description: $0.description,
                                                           recommended: $0.recommended) },
                multiSelect: multi))
        case .note(_, let text, _):
            return .note(text)
        }
    }
}

// MARK: - Focus helpers for the TF2/TF3 tests

/// Under the Focus layout a group that has a message after it folds into a collapsed activity row, so
/// a TF2/TF3 test that needs to see that group opens the row (or ends the turn on the group, so it
/// is the trailing group and renders at the top level as it always did).
extension FoldFixtures {

    /// The keys of the turn's activity rows (`ActivitySegment.key`), in order.
    static func activityKeys(of turn: ChatTurn) -> [String] {
        let blocks = turn.blocks.enumerated().map { foldBlock($1, at: $0, in: turn) }
        return FocusPlanner.plan(blocks: blocks, outcome: outcome(of: turn), turnKey: turn.identityKey)
            .compactMap { if case .activity(let segment) = $0 { return segment.key } else { return nil } }
    }

    /// `folds` with every activity row of `turn` opened by the operator. Tool groups are untouched.
    static func rowsOpen(_ turn: ChatTurn, in folds: FoldResolver = FoldResolver()) -> FoldResolver {
        var folds = folds
        for key in activityKeys(of: turn) { folds.activityStates[key] = true }
        return folds
    }
}

// MARK: - ToolFoldAdapterTests

final class ToolFoldAdapterTests: XCTestCase {

    private typealias F = FoldFixtures

    // MARK: block -> fold block

    func testNonBlankTextIsProseAndWhitespaceOnlyTextIsEmptyProse() {
        let turn = F.turn([.text("hello"), .text("  \n\t "), .text("")])
        XCTAssertEqual(ToolFoldAdapter.foldBlock(turn.blocks[0], at: 0, in: turn), .prose(nonEmpty: true, parentId: nil))
        XCTAssertEqual(ToolFoldAdapter.foldBlock(turn.blocks[1], at: 1, in: turn), .prose(nonEmpty: false, parentId: nil))
        XCTAssertEqual(ToolFoldAdapter.foldBlock(turn.blocks[2], at: 2, in: turn), .prose(nonEmpty: false, parentId: nil))
    }

    func testSubagentProseCarriesItsAgentFromTheTurnsTextParentMap() {
        let turn = F.turn([.text("main"), .text("sub said this")], textParents: [1: "toolu_agent"])
        XCTAssertEqual(ToolFoldAdapter.foldBlock(turn.blocks[0], at: 0, in: turn), .prose(nonEmpty: true, parentId: nil))
        XCTAssertEqual(ToolFoldAdapter.foldBlock(turn.blocks[1], at: 1, in: turn),
                       .prose(nonEmpty: true, parentId: "toolu_agent"))
    }

    func testToolCallCarriesEveryFactTheFoldRuleNeeds() {
        let started = F.at(10), finished = F.at(12)
        let data = ToolCallData(toolName: "Edit", inputSummary: "b.swift", inputFull: "{\"file_path\":\"/a/b.swift\"}",
                                toolUseId: "toolu_1", parentToolUseId: "toolu_agent", target: "/a/b.swift",
                                startedAt: started, finishedAt: finished)
        let turn = F.turn([.toolCall(data)])
        XCTAssertEqual(ToolFoldAdapter.foldBlock(turn.blocks[0], at: 0, in: turn),
                       .toolCall(FoldCall(name: "Edit", toolUseId: "toolu_1", parentId: "toolu_agent",
                                          target: "/a/b.swift", startedAt: started, finishedAt: finished,
                                          inputSummary: "b.swift", inputFull: "{\"file_path\":\"/a/b.swift\"}")))
    }

    func testToolCallFromAnOlderDaemonHasNoOptionalFacts() {
        let turn = F.turn([.toolCall(ToolCallData(toolName: "Bash", inputSummary: "ls", inputFull: "{}"))])
        XCTAssertEqual(ToolFoldAdapter.foldBlock(turn.blocks[0], at: 0, in: turn),
                       .toolCall(FoldCall(name: "Bash", inputSummary: "ls", inputFull: "{}")))
    }

    func testToolResultCarriesItsCallIdParentErrorFlagAndTime() {
        let turn = F.turn([F.result("boom", id: "toolu_1", isError: true, parent: "toolu_agent", time: 7)])
        XCTAssertEqual(ToolFoldAdapter.foldBlock(turn.blocks[0], at: 0, in: turn),
                       .toolResult(FoldResult(toolUseId: "toolu_1", parentId: "toolu_agent", isError: true,
                                              at: F.at(7))))
    }

    func testEveryNonToolBlockIsABoundary() {
        let turn = F.turn([F.chip(), .errorMessage("boom"), F.question(), .note("Model changed.")])
        let kinds = turn.blocks.enumerated().map { ToolFoldAdapter.foldBlock($1, at: $0, in: turn) }
        XCTAssertEqual(kinds, [.boundary(.resultSummary), .boundary(.errorMessage),
                               .boundary(.askQuestion), .boundary(.note)])
    }

    func testFoldBlocksAreParallelToTheTurnsBlocks() {
        let turn = F.turn([.text("a")] + F.run(2) + [F.chip()], textParents: [:])
        let folds = ToolFoldAdapter.foldBlocks(of: turn)
        XCTAssertEqual(folds.count, turn.blocks.count)
        for (i, block) in turn.blocks.enumerated() {
            XCTAssertEqual(folds[i], ToolFoldAdapter.foldBlock(block, at: i, in: turn), "block \(i)")
        }
    }

    // MARK: how a turn ended

    func testAnIncompleteTurnIsOpenWhatEverItHolds() {
        let turn = F.turn(F.run(2) + [.errorMessage("boom")], complete: false)
        XCTAssertEqual(ToolFoldAdapter.outcome(of: turn), .open)
    }

    func testACompletedTurnWithNothingWrongCompletedOk() {
        XCTAssertEqual(ToolFoldAdapter.outcome(of: F.turn(F.run(2) + [F.chip()])), .completedOk)
        XCTAssertEqual(ToolFoldAdapter.outcome(of: F.turn(F.run(2))), .completedOk, "a turn with no result chip at all")
    }

    func testAnInterruptedResultChipMeansTheOperatorStoppedTheTurn() {
        // The CLI reports a stopped turn as an error result; the interrupted flag is what says why.
        let chip = TurnBlock.resultSummary(ResultSummaryData(durationMs: 1, costUSD: 0, isError: true, interrupted: true))
        XCTAssertEqual(ToolFoldAdapter.outcome(of: F.turn(F.run(1) + [chip])), .interrupted)
    }

    func testAnErrorResultChipMeansTheTurnCompletedInError() {
        let chip = TurnBlock.resultSummary(ResultSummaryData(durationMs: 1, costUSD: 0, isError: true))
        XCTAssertEqual(ToolFoldAdapter.outcome(of: F.turn(F.run(1) + [chip])), .completedError)
    }

    func testAnErrorMessageBlockMeansTheTurnErrored() {
        XCTAssertEqual(ToolFoldAdapter.outcome(of: F.turn(F.run(1) + [.errorMessage("child exited")])), .errored)
        XCTAssertEqual(ToolFoldAdapter.outcome(of: F.turn(F.run(1) + [.errorMessage("child exited"), F.chip()])), .errored,
                       "an ok chip does not cancel an error message")
    }

    func testAnErrorResultChipOutranksAnErrorMessage() {
        let chip = TurnBlock.resultSummary(ResultSummaryData(durationMs: 1, costUSD: 0, isError: true))
        XCTAssertEqual(ToolFoldAdapter.outcome(of: F.turn([.errorMessage("child exited"), chip])), .completedError)
    }

    // MARK: plan

    func testPlanFoldsAProseCallsProseTurnIntoThreeItems() {
        let turn = F.turn([.text("before")] + F.run(4) + [.text("after")])
        let items = ToolFoldAdapter.plan(turn)
        XCTAssertEqual(items.count, 3)
        guard items.count == 3, case .block(0) = items[0], case .group(let g) = items[1], case .block(9) = items[2]
        else { return XCTFail("unexpected items \(items)") }
        XCTAssertEqual(g.callCount, 4)
        XCTAssertEqual(g.memberIndices, Array(1 ... 8))
    }

    func testPlanKeysAGroupByItsFirstCallsToolUseId() {
        let items = ToolFoldAdapter.plan(F.turn(F.run(2, prefix: "toolu_")))
        guard case .group(let g)? = items.first else { return XCTFail("no group in \(items)") }
        XCTAssertEqual(g.key, "g:toolu_0")
    }

    func testPlanKeysAnIdlessGroupByTheTurnsIdentityAndTheCallsOrdinal() {
        let blocks: [TurnBlock] = [F.call(summary: "a"), F.result(), F.call(summary: "b"), .text("break"),
                                   F.call(summary: "c")]
        let turn = F.turn(blocks)
        let groups = ToolFoldAdapter.plan(turn).compactMap { item -> ToolGroup? in
            if case .group(let g) = item { return g } else { return nil }
        }
        XCTAssertEqual(groups.map(\.key), ["g:\(turn.identityKey)#c0", "g:\(turn.identityKey)#c2"])
    }

    func testANoteBetweenTwoCallsSplitsThemIntoTwoGroups() {
        let blocks = F.run(2, prefix: "a") + [.note("Model changed to Opus (from Sonnet) by you.")] + F.run(2, prefix: "b")
        let items = ToolFoldAdapter.plan(F.turn(blocks))
        XCTAssertEqual(items.count, 3)
        guard items.count == 3, case .group(let first) = items[0], case .block(4) = items[1],
              case .group(let second) = items[2] else { return XCTFail("unexpected items \(items)") }
        XCTAssertEqual(first.key, "g:a0")
        XCTAssertEqual(second.key, "g:b0")
    }

    func testPlanUsesTheTurnsOutcomeSoACompletedTurnHasNoRunningGroup() {
        // A call with no result in an open turn is running; once the turn completes it is not.
        let blocks: [TurnBlock] = [F.call(id: "u1", summary: "sleep 9")]
        guard case .group(let open)? = ToolFoldAdapter.plan(F.turn(blocks, complete: false)).first,
              case .group(let done)? = ToolFoldAdapter.plan(F.turn(blocks, complete: true)).first
        else { return XCTFail("no group") }
        XCTAssertEqual(open.state, .running)
        XCTAssertEqual(done.state, .settled)
    }

    func testPlanMatchesNostromoKitsPlannerOverTheSameBlocks() {
        let blocks = [TurnBlock.text("x")] + F.run(3) + [F.question()] + F.run(1, prefix: "z") + [F.chip()]
        let turn = F.turn(blocks)
        XCTAssertEqual(ToolFoldAdapter.plan(turn),
                       ToolFoldPlanner.plan(blocks: F.turn(blocks).blocks.enumerated().map { F.foldBlock($1, at: $0, in: turn) },
                                            outcome: .completedOk, turnKey: turn.identityKey))
    }

    // MARK: the resolver

    func testAnExplicitChoiceBeatsTheDefaultEitherWay() {
        let group = F.plainGroup(calls: 2)
        XCTAssertFalse(FoldResolver().isExpanded(group), "collapsed unless told otherwise")
        XCTAssertTrue(FoldResolver(expandedByDefault: true).isExpanded(group))
        XCTAssertTrue(FoldResolver(groupStates: [group.key: true]).isExpanded(group))
        XCTAssertFalse(FoldResolver(groupStates: [group.key: false], expandedByDefault: true).isExpanded(group),
                       "an operator's close survives an expanded default")
        XCTAssertTrue(FoldResolver(groupStates: ["g:other": false], expandedByDefault: true).isExpanded(group),
                      "another group's choice does not apply")
    }

    func testTheResolversExplicitLookupsReadItsOwnChoices() {
        let group = F.plainGroup(calls: 2)
        var folds = FoldResolver(groupStates: [group.key: true], groupAuto: ["g:auto"],
                                 activityStates: ["a:x": false])
        XCTAssertEqual(folds.explicitGroup(group.key), true)
        XCTAssertNil(folds.explicitGroup("g:other"))
        XCTAssertTrue(folds.isAuto("g:auto"))
        XCTAssertFalse(folds.isAuto(group.key))
        XCTAssertEqual(folds.explicitActivity("a:x"), false)
        XCTAssertNil(folds.explicitActivity("a:y"))
        folds.resultStates[4] = true
        XCTAssertEqual(folds.explicitResult(block: nil, index: 4), true)
        XCTAssertNil(folds.explicitResult(block: nil, index: 5))
    }

    // MARK: height-cache digest

    private func twoGroupTurn() -> ChatTurn {
        F.turn(F.run(2, prefix: "a") + [.text("between")] + F.run(2, prefix: "b"))
    }

    /// The digest of `turn` as `TurnListVirtualizer` builds it: through the turn's fold shape.
    private func digest(_ turn: ChatTurn, _ folds: FoldResolver = FoldResolver(), held: Set<Int> = []) -> String {
        ToolFoldAdapter.foldDigest(turn: turn, shape: FoldShape(turn), folds: folds, held: held)
    }

    func testTheDigestIsEmptyWhenTheOperatorHasChosenNothing() {
        XCTAssertEqual(digest(twoGroupTurn()), "")
        XCTAssertNotEqual(digest(twoGroupTurn(), held: [1]), "", "a held roll-in changes the rows")
    }

    func testDifferentExplicitGroupChoicesDigestDifferently() {
        let turn = twoGroupTurn()
        func digest(_ states: [String: Bool]) -> String {
            self.digest(turn, FoldResolver(groupStates: states))
        }
        let none = digest([:])
        let openA = digest(["g:a0": true])
        let openB = digest(["g:b0": true])
        let openBoth = digest(["g:a0": true, "g:b0": true])
        XCTAssertNotEqual(openA, none)
        XCTAssertNotEqual(openA, openB, "which group is open matters")
        XCTAssertNotEqual(openA, openBoth)
        XCTAssertNotEqual(digest(["g:a0": false]), openA, "an explicit close is not an explicit open")
    }

    func testAnExpandedResultInsideAnOpenGroupChangesTheDigest() {
        let turn = twoGroupTurn()
        var groupOnly = FoldResolver()
        groupOnly.groupStates["g:a0"] = true
        var withResult = groupOnly
        withResult.resultStates = [1: true]
        var otherResult = groupOnly
        otherResult.resultStates = [3: true]
        let a = digest(turn, groupOnly)
        let b = digest(turn, withResult)
        let c = digest(turn, otherResult)
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(b, c)
    }

    func testTheDigestIsDeterministic() {
        let turn = twoGroupTurn()
        var s = FoldResolver()
        s.groupStates = ["g:a0": true, "g:b0": false]
        s.resultStates = [1: true, 3: true]
        XCTAssertEqual(digest(turn, s), digest(turn, s))
        XCTAssertEqual(digest(turn, s), digest(turn, s))
    }

    func testTheDigestDoesNotDependOnTheOrderChoicesWereMade() {
        // Many entries inserted in opposite orders: a digest that walks a dictionary in iteration
        // order, rather than sorting, would disagree with itself.
        let blocks = (0 ..< 30).flatMap { F.run(1, prefix: "k\($0)_") + [TurnBlock.text("p\($0)")] }
        let turn = F.turn(blocks)
        let keys = (0 ..< 30).map { "g:k\($0)_0" }
        var forward = FoldResolver(), backward = FoldResolver()
        for (i, key) in keys.enumerated() { forward.groupStates[key] = i % 2 == 0 }
        for (i, key) in keys.enumerated().reversed() { backward.groupStates[key] = i % 2 == 0 }
        for i in 0 ..< 30 { forward.resultStates[i * 3 + 1] = true }
        for i in (0 ..< 30).reversed() { backward.resultStates[i * 3 + 1] = true }
        XCTAssertEqual(forward, backward)
        XCTAssertEqual(digest(turn, forward), digest(turn, backward))
    }

    func testAnExpandedDefaultDigestsDifferentlyFromACollapsedOne() {
        let turn = twoGroupTurn()
        XCTAssertNotEqual(digest(turn, FoldResolver(expandedByDefault: true)),
                          digest(turn, FoldResolver(expandedByDefault: false)),
                          "a height measured with every group open must not be reused for a collapsed pane")
    }

    // MARK: row counts for diagnostics

    func testACollapsedGroupIsOneRowAndAnExpandedGroupAddsItsMembers() {
        // Ends on the group (the trailing group renders at the top level): a, 8 members.
        let turn = F.turn([.text("a")] + F.run(4))
        let key = F.groups(of: turn)[0].key
        let collapsed = ToolFoldAdapter.rowCounts(turns: [turn]) { _ in FoldResolver() }
        XCTAssertEqual(collapsed.rows, 2)
        XCTAssertEqual(collapsed.groups, 1)
        let expanded = ToolFoldAdapter.rowCounts(turns: [turn]) { _ in FoldResolver(groupStates: [key: true]) }
        XCTAssertEqual(expanded.rows, 1 + (1 + 8))
        XCTAssertEqual(expanded.groups, 1)
        let byDefault = ToolFoldAdapter.rowCounts(turns: [turn]) { _ in FoldResolver(expandedByDefault: true) }
        XCTAssertEqual(byDefault.rows, expanded.rows)
    }

    func testRowCountsSumOverTurnsAndEachTurnUsesItsOwnResolver() {
        let one = F.turn([.text("a")] + F.run(2, prefix: "x"), raw: "2026-10-13T00:00:01.000Z")
        let two = F.turn(F.run(3, prefix: "y") + [F.chip()], raw: "2026-10-13T00:00:02.000Z")
        let empty = F.turn([], raw: "2026-10-13T00:00:03.000Z")
        let oneKey = F.groups(of: one)[0].key
        let counts = ToolFoldAdapter.rowCounts(turns: [one, two, empty]) { turn in
            turn.identityKey == one.identityKey ? FoldResolver(groupStates: [oneKey: true]) : FoldResolver()
        }
        // one: prose + (group + 4 members) = 6 ; two: group + chip = 2 ; empty: 0
        XCTAssertEqual(counts.rows, 6 + 2 + 0)
        XCTAssertEqual(counts.groups, 2)
    }

    func testRowCountsOfNoTurnsAreZero() {
        let counts = ToolFoldAdapter.rowCounts(turns: []) { _ in FoldResolver() }
        XCTAssertEqual(counts.rows, 0)
        XCTAssertEqual(counts.groups, 0)
    }

    func testTheBenchmarkSessionHasSixtyPercentFewerRowsCollapsedThanBlocks() throws {
        let turns = try F.benchmarkTurns()
        let blocks = turns.reduce(0) { $0 + $1.blocks.count }
        let counts = ToolFoldAdapter.rowCounts(turns: turns) { _ in FoldResolver() }
        XCTAssertGreaterThan(counts.groups, 0)
        XCTAssertLessThanOrEqual(Double(counts.rows), Double(blocks) * 0.4,
                                 "collapsed, the pane shows \(counts.rows) rows for \(blocks) blocks")
    }
}
