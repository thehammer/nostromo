import XCTest
@testable import NostromoKit

/// The words on an activity row (PRD "The activity row"; contract §2.1 `ActivitySummary`) and
/// the three copy texts. Segments are built by hand where the test is about wording, and
/// through `FocusPlanner.plan` where it is about what a real turn reads as.
final class ActivitySummaryTests: XCTestCase {

    // MARK: Builders

    private let t0 = Date(timeIntervalSince1970: 2_000_000)
    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    private func tool(_ name: String, target: String? = nil, summary: String = "", full: String = "") -> FoldCall {
        FoldCall(name: name, target: target, inputSummary: summary, inputFull: full)
    }

    private func bashes(_ n: Int) -> [FoldCall] { (0 ..< n).map { tool("Bash", summary: "cmd \($0)") } }
    private func reads(_ targets: String...) -> [FoldCall] { targets.map { tool("Read", target: $0) } }
    private func edits(_ n: Int) -> [FoldCall] { (0 ..< n).map { tool("Edit", target: "e\($0).swift") } }

    private func group(_ id: Int, _ calls: [FoldCall], failed: Int = 0, start: Double? = nil, end: Double? = nil,
                       stuck: Bool = false) -> ToolGroup {
        var g = ToolGroup(id: id, key: "g:t\(id)")
        g.calls = calls
        g.finishedCount = calls.count
        g.failedCount = failed
        g.startedAt = start.map(at)
        g.endedAt = end.map(at)
        g.state = .settled
        g.isStuck = stuck
        return g
    }

    private func message(_ ordinal: Int, _ blockIndices: [Int]? = nil) -> ActivityMember {
        .message(MessageRef(ordinal: ordinal, blockIndices: blockIndices ?? [ordinal * 10]))
    }

    private func messages(_ n: Int) -> [ActivityMember] { (0 ..< n).map { message($0) } }

    private func segment(_ members: [ActivityMember], live: Bool = false) -> ActivitySegment {
        ActivitySegment(key: "a:test", members: members, isLive: live)
    }

    // MARK: Computed properties

    func testAnActivityRowCountsItsMessagesAndGathersTheCallsOfEveryGroupInOrder() {
        let g0 = group(0, [tool("Bash", summary: "one"), tool("Read", target: "a")])
        let g1 = group(1, [tool("Edit", target: "b"), tool("Bash", summary: "four")])
        let s = segment([message(0), .group(g0), message(1), .group(g1)])

        XCTAssertEqual(s.messageCount, 2)
        XCTAssertEqual(s.calls.map(\.name), ["Bash", "Read", "Edit", "Bash"])
        XCTAssertEqual(s.calls.map(\.inputSummary), ["one", "", "", "four"])
    }

    func testARowOfOnlyGroupsHasNoMessages() {
        let s = segment([.group(group(0, bashes(2))), .group(group(1, bashes(1)))])

        XCTAssertEqual(s.messageCount, 0)
        XCTAssertEqual(s.calls.count, 3)
    }

    func testARowOfOnlyMessagesHasNoCallsNoFailuresAndNoTimes() {
        let s = segment(messages(2))

        XCTAssertEqual(s.calls, [])
        XCTAssertEqual(s.failedCount, 0)
        XCTAssertNil(s.startedAt)
        XCTAssertNil(s.endedAt)
        XCTAssertFalse(s.containsStuckGroup)
    }

    func testFailuresAreSummedAcrossTheGroups() {
        let s = segment([.group(group(0, bashes(3), failed: 2)), message(0), .group(group(1, bashes(2), failed: 1))])

        XCTAssertEqual(s.failedCount, 3)
    }

    func testStartIsTheFirstGroupsStartEvenWhenALaterGroupStartedEarlierOnTheClock() {
        let s = segment([.group(group(0, bashes(1), start: 10, end: 12)), .group(group(1, bashes(1), start: 5, end: 20))])

        XCTAssertEqual(s.startedAt, at(10))
    }

    func testStartIsUnknownWhenTheFirstGroupHasNoStartEvenIfALaterOneDoes() {
        let s = segment([.group(group(0, bashes(1), start: nil, end: 12)), .group(group(1, bashes(1), start: 5, end: 20))])

        XCTAssertNil(s.startedAt)
    }

    func testEndIsTheLatestEndAmongTheGroupsThatKnowTheirs() {
        let s = segment([.group(group(0, bashes(1), start: 1, end: 60)), message(0), .group(group(1, bashes(1), start: 2, end: 50))])

        XCTAssertEqual(s.endedAt, at(60))
    }

    func testEndIgnoresGroupsWhoseEndIsUnknown() {
        let s = segment([.group(group(0, bashes(1), start: 1, end: 7)), .group(group(1, bashes(1), start: 2, end: nil))])

        XCTAssertEqual(s.endedAt, at(7))
    }

    func testEndIsUnknownWhenNoGroupKnowsItsEnd() {
        let s = segment([.group(group(0, bashes(1), start: 1, end: nil)), .group(group(1, bashes(1), start: 2, end: nil))])

        XCTAssertNil(s.endedAt)
    }

    func testARowContainsAStuckGroupExactlyWhenOneOfItsGroupsIsStuck() {
        let calm = segment([.group(group(0, bashes(1))), .group(group(1, bashes(1)))])
        let stuck = segment([.group(group(0, bashes(1))), message(0), .group(group(1, bashes(1), failed: 1, stuck: true))])

        XCTAssertFalse(calm.containsStuckGroup)
        XCTAssertTrue(stuck.containsStuckGroup)
    }

    // MARK: Title

    func testTheTitleLeadsWithTheMessagesThenTheCallPhrasesAndCountsTheHiddenCalls() {
        // 9 commands, 2 files read, 3 edits (3 calls) and 1 search (1 call) behind "+N more".
        let g0 = group(0, bashes(5) + reads("a", "b"))
        let g1 = group(1, bashes(4) + edits(3) + [tool("Grep")])
        // Hand-built: two message members may sit side by side here.
        let s = segment([message(0), .group(g0), message(1), message(2), .group(g1)])

        XCTAssertEqual(s.messageCount, 3)
        XCTAssertEqual(ActivitySummary.title(for: s), "3 messages, ran 9 commands, read 2 files, +4 more")
    }

    func testOneMessageIsSingular() {
        let s = segment([message(0), .group(group(0, bashes(2)))])

        XCTAssertEqual(ActivitySummary.title(for: s), "1 message, ran 2 commands")
    }

    func testARowOfOnlyMessagesReadsAsJustTheMessages() {
        XCTAssertEqual(ActivitySummary.title(for: segment(messages(2))), "2 messages")
        XCTAssertEqual(ActivitySummary.title(for: segment(messages(1))), "1 message")
        XCTAssertEqual(ActivitySummary.plainText(for: segment(messages(2))), "2 messages")
    }

    func testTheMessagesPhraseCountsTowardsTheThreePhraseCap() {
        let twoPhrases = segment([message(0), .group(group(0, bashes(1) + reads("a")))])
        let threePhrases = segment([message(0), .group(group(0, bashes(1) + reads("a") + edits(2)))])
        let fourPhrases = segment([message(0), .group(group(0, bashes(1) + reads("a") + edits(2) + [tool("Grep"), tool("Grep")]))])

        XCTAssertEqual(ActivitySummary.title(for: twoPhrases), "1 message, ran 1 command, read 1 file")
        XCTAssertEqual(ActivitySummary.title(for: threePhrases), "1 message, ran 1 command, read 1 file, +2 more")
        XCTAssertEqual(ActivitySummary.title(for: fourPhrases), "1 message, ran 1 command, read 1 file, +4 more")
    }

    func testARowWithNoMessagesCapitalisesItsFirstPhrase() {
        let s = segment([.group(group(0, bashes(5))), .group(group(1, bashes(4) + reads("a", "b")))])

        XCTAssertEqual(ActivitySummary.title(for: s), "Ran 9 commands, read 2 files")
    }

    func testARowWithNoMessagesShowsThreePhrasesThenMore() {
        let three = segment([.group(group(0, bashes(1) + reads("a") + edits(1)))])
        let five = segment([.group(group(0, bashes(1) + reads("a") + edits(1) + [tool("Grep"), tool("WebFetch"), tool("WebFetch")]))])

        XCTAssertEqual(ActivitySummary.title(for: three), "Ran 1 command, read 1 file, edited 1 file")
        XCTAssertEqual(ActivitySummary.title(for: five), "Ran 1 command, read 1 file, edited 1 file, +3 more")
    }

    func testARowOfOneSingleCallStillReadsAsAPhrase() {
        // A group of one shows its own header on a group row; an activity row has no header.
        let s = segment([.group(group(0, bashes(1)))])

        XCTAssertEqual(ActivitySummary.title(for: s), "Ran 1 command")
    }

    func testPhrasesAreComputedOverEveryCallOfTheRowNotPerGroup() {
        // The same file read in two groups is one file; commands add up across groups.
        let s = segment([message(0), .group(group(0, bashes(2) + reads("a.swift"))), message(1),
                         .group(group(1, bashes(3) + reads("a.swift")))])

        XCTAssertEqual(ActivitySummary.title(for: s), "2 messages, ran 5 commands, read 1 file")
    }

    func testTheCallPhrasesAreTheOnesAToolGroupWithTheSameCallsWouldShow() {
        let tables: [[FoldCall]] = [
            bashes(3) + reads("a", "b"),
            [tool("Edit", target: "x"), tool("Read", target: "y"), tool("Bash"), tool("Grep"), tool("Task"), tool("TodoWrite")],
            [tool("mcp__alpha__a"), tool("mcp__beta__b"), tool("mcp__alpha__c"), tool("Frobnicate"), tool("WebSearch")],
            [tool("Read"), tool("Read")],
            HostileContent.mcpToolNames.map { tool($0) },
            bashes(2),
        ]
        for calls in tables {
            let oracle = ToolGroupSummary.summary(for: group(0, calls))
            let split = calls.count / 2
            let s = segment([.group(group(0, Array(calls.prefix(split)))), .group(group(1, Array(calls.dropFirst(split))))])
            XCTAssertEqual(ActivitySummary.title(for: s), oracle, "calls \(calls.map(\.name))")
        }
    }

    func testTheTitleOfARealTurnReadsAsThePRDExample() {
        // prose A, 4 commands, prose B, 3 distinct reads, prose C
        var blocks: [FoldBlock] = [.prose(nonEmpty: true)]
        for n in 0 ..< 4 { blocks += [.toolCall(FoldCall(name: "Bash", toolUseId: "b\(n)")), .toolResult(FoldResult(toolUseId: "b\(n)"))] }
        blocks.append(.prose(nonEmpty: true))
        for n in 0 ..< 3 { blocks += [.toolCall(FoldCall(name: "Read", toolUseId: "r\(n)", target: "f\(n)")), .toolResult(FoldResult(toolUseId: "r\(n)"))] }
        blocks.append(.prose(nonEmpty: true))

        let items = FocusPlanner.plan(blocks: blocks, outcome: .completedOk, turnKey: "T")

        guard case .activity(let s)? = items.first else { return XCTFail("expected an activity row first, got \(items)") }
        XCTAssertEqual(ActivitySummary.title(for: s), "2 messages, ran 4 commands, read 3 files")
        XCTAssertEqual(ActivitySummary.plainText(for: s), "2 messages, ran 4 commands, read 3 files")
    }

    func testSubagentCallsAndFailuresAreNotPartOfTheRowsWords() {
        let blocks: [FoldBlock] = [
            .toolCall(FoldCall(name: "Agent", toolUseId: "a")),
            .toolCall(FoldCall(name: "Bash", toolUseId: "s1", parentId: "a")),
            .toolResult(FoldResult(toolUseId: "s1", parentId: "a", isError: true)),
            .toolResult(FoldResult(toolUseId: "a")),
            .prose(nonEmpty: true),
        ]

        let items = FocusPlanner.plan(blocks: blocks, outcome: .completedOk, turnKey: "T")

        guard case .activity(let s)? = items.first else { return XCTFail("expected an activity row first, got \(items)") }
        XCTAssertEqual(ActivitySummary.title(for: s), "Ran 1 agent")
        XCTAssertNil(ActivitySummary.failureText(for: s))
        XCTAssertEqual(s.calls.map(\.name), ["Agent"])
    }

    func testTheTitleOfHostileToolNamesIsSafeToDrawOnOneLine() {
        for hostile in HostileContent.all {
            let s = segment([message(0), .group(group(0, [tool("mcp__\(hostile)__t")]))])
            for text in [ActivitySummary.title(for: s), ActivitySummary.plainText(for: s)] {
                XCTAssertFalse(text.unicodeScalars.contains(where: HostileContent.isForbiddenOnARow), "hostile \(hostile.prefix(20))")
                XCTAssertLessThanOrEqual(text.utf16.count, FoldTextSanitizer.maxUTF16)
            }
        }
    }

    func testAnOverlongTitleIsCappedAtTheSanitizersLimit() {
        let longServer = String(repeating: "s", count: 2_000)
        let s = segment([message(0), .group(group(0, [tool("mcp__\(longServer)__t")]))])

        let title = ActivitySummary.title(for: s)

        XCTAssertTrue(title.hasPrefix("1 message, used 1 s"))
        XCTAssertLessThanOrEqual(title.utf16.count, FoldTextSanitizer.maxUTF16)
    }

    // MARK: Failure

    func testFailureTextIsTheSumOfTheFailuresInTheRow() {
        let s = segment([.group(group(0, bashes(3), failed: 2)), message(0), .group(group(1, bashes(2), failed: 1))])

        XCTAssertEqual(ActivitySummary.failureText(for: s), "3 failed")
    }

    func testFailureTextIsNilWhenNothingFailed() {
        XCTAssertNil(ActivitySummary.failureText(for: segment([message(0), .group(group(0, bashes(3)))])))
        XCTAssertNil(ActivitySummary.failureText(for: segment(messages(1))))
    }

    // MARK: Duration

    func testDurationRunsFromTheFirstStartToTheLatestEnd() {
        let s = segment([.group(group(0, bashes(1), start: 100, end: 102)), message(0), .group(group(1, bashes(1), start: 103, end: 104.1))])

        XCTAssertEqual(ActivitySummary.durationText(for: s), "4.1 s")
        XCTAssertEqual(ActivitySummary.durationText(for: s), ToolGroupSummary.durationText(seconds: 4.1))
    }

    func testDurationUsesTheLatestEndEvenWhenAnEarlierGroupEndedLast() {
        let s = segment([.group(group(0, bashes(1), start: 0, end: 41)), .group(group(1, bashes(1), start: 5, end: 9))])

        XCTAssertEqual(ActivitySummary.durationText(for: s), ToolGroupSummary.durationText(seconds: 41))
    }

    func testDurationIsNilWhenTheStartIsUnknown() {
        let s = segment([.group(group(0, bashes(1), start: nil, end: 10)), .group(group(1, bashes(1), start: 3, end: 20))])

        XCTAssertNil(ActivitySummary.durationText(for: s))
    }

    func testDurationIsNilWhenNoEndIsKnown() {
        let s = segment([.group(group(0, bashes(1), start: 0, end: nil))])

        XCTAssertNil(ActivitySummary.durationText(for: s))
    }

    func testARowOfOnlyMessagesHasNoDuration() {
        XCTAssertNil(ActivitySummary.durationText(for: segment(messages(3))))
    }

    func testADurationUnderAMillisecondIsLeftOutNeverZeroMs() {
        let s = segment([.group(group(0, bashes(1), start: 7, end: 7))])

        XCTAssertNil(ActivitySummary.durationText(for: s))
        XCTAssertFalse(ActivitySummary.plainText(for: s).contains("0 ms"))
    }

    // MARK: Documenting: startedAt / endedAt of a row

    // The contract (documented by these tests; no behaviour change): `startedAt` is the FIRST
    // group's start, and is nil when that group has none, even if a later group has times;
    // `endedAt` is the latest known end among the groups that know theirs, and a later group
    // that is still running is ignored (it does not make the end unknown).

    func testWhenTheFirstGroupHasNoTimesTheRowHasNoStartEvenIfALaterGroupHasTimes() {
        let s = segment([.group(group(0, bashes(1))), message(0), .group(group(1, bashes(1), start: 5, end: 9))])

        XCTAssertNil(s.startedAt, "the start is the first group's, not the earliest known")
        XCTAssertEqual(s.endedAt, at(9), "the end is still the latest known end")
        XCTAssertNil(ActivitySummary.durationText(for: s), "no start, no duration")
        XCTAssertEqual(ActivitySummary.plainText(for: s), "1 message, ran 2 commands")
    }

    func testALaterGroupStillRunningDoesNotMakeTheRowsEndUnknown() {
        var running = group(1, bashes(1), start: 8, end: nil)
        running.finishedCount = 0
        running.state = .running
        let s = segment([.group(group(0, bashes(1), start: 2, end: 6)), message(0), .group(running)])

        XCTAssertEqual(s.startedAt, at(2))
        XCTAssertEqual(s.endedAt, at(6), "the running group's end is unknown and is ignored")
        XCTAssertEqual(ActivitySummary.durationText(for: s), ToolGroupSummary.durationText(seconds: 4))
    }

    func testARowWhoseOnlyGroupWithTimesIsStillRunningHasNoEndAndNoDuration() {
        var running = group(0, bashes(1), start: 8, end: nil)
        running.finishedCount = 0
        running.state = .running
        let s = segment([.group(running)])

        XCTAssertEqual(s.startedAt, at(8))
        XCTAssertNil(s.endedAt)
        XCTAssertNil(ActivitySummary.durationText(for: s))
    }

    func testTheSameTimesContractHoldsForARealPlannedTurn() {
        // First group: no start time, ends at 3. Second: starts at 5, ends at 9. Third: starts at 10, never finishes.
        let blocks: [FoldBlock] = [
            .toolCall(FoldCall(name: "Bash", toolUseId: "a")), .toolResult(FoldResult(toolUseId: "a", at: at(3))),
            .prose(nonEmpty: true),
            .toolCall(FoldCall(name: "Bash", toolUseId: "b", startedAt: at(5))), .toolResult(FoldResult(toolUseId: "b", at: at(9))),
            .prose(nonEmpty: true),
            .toolCall(FoldCall(name: "Bash", toolUseId: "c", startedAt: at(10))),
            .prose(nonEmpty: true),
        ]

        let items = FocusPlanner.plan(blocks: blocks, outcome: .open, turnKey: "T")

        guard case .activity(let s)? = items.first else { return XCTFail("expected a row first, got \(items)") }
        XCTAssertNil(s.startedAt)
        XCTAssertEqual(s.endedAt, at(9), "the unfinished third group is ignored")
        XCTAssertNil(ActivitySummary.durationText(for: s))
    }

    func testTheEndOfARealPlannedRowIgnoresALaterUnfinishedGroupAndStartsAtTheFirst() {
        let blocks: [FoldBlock] = [
            .toolCall(FoldCall(name: "Bash", toolUseId: "a", startedAt: at(1))), .toolResult(FoldResult(toolUseId: "a", at: at(5))),
            .prose(nonEmpty: true),
            .toolCall(FoldCall(name: "Bash", toolUseId: "b", startedAt: at(6))),
            .prose(nonEmpty: true),
        ]

        let items = FocusPlanner.plan(blocks: blocks, outcome: .open, turnKey: "T")

        guard case .activity(let s)? = items.first else { return XCTFail("expected a row first, got \(items)") }
        XCTAssertEqual(s.startedAt, at(1))
        XCTAssertEqual(s.endedAt, at(5))
        XCTAssertEqual(ActivitySummary.durationText(for: s), ToolGroupSummary.durationText(seconds: 4))
    }

    // MARK: Plain text and the accessibility label

    private func richRow() -> ActivitySegment {
        // 3 messages, 9 commands, 2 files read, 3 edits and a search: 1 failed, 41 s.
        let g0 = group(0, bashes(5) + reads("a", "b"), failed: 1, start: 0, end: 20)
        let g1 = group(1, bashes(4) + edits(3) + [tool("Grep")], start: 21, end: 41)
        return segment([message(0), .group(g0), message(1), message(2), .group(g1)])
    }

    func testPlainTextJoinsTitleFailureAndTimeWithMiddleDots() {
        let expectedTime = ToolGroupSummary.durationText(seconds: 41)!

        XCTAssertEqual(ActivitySummary.plainText(for: richRow()),
                       "3 messages, ran 9 commands, read 2 files, +4 more · 1 failed · \(expectedTime)")
        XCTAssertEqual(ToolGroupSummary.separator, " · ")
    }

    func testPlainTextSkipsTheFailureAndTheTimeWhenAbsent() {
        let noFailure = segment([message(0), .group(group(0, bashes(2), start: 0, end: 4.1))])
        let noTime = segment([message(0), .group(group(0, bashes(2), failed: 2))])
        let neither = segment([message(0), .group(group(0, bashes(2)))])

        XCTAssertEqual(ActivitySummary.plainText(for: noFailure), "1 message, ran 2 commands · 4.1 s")
        XCTAssertEqual(ActivitySummary.plainText(for: noTime), "1 message, ran 2 commands · 2 failed")
        XCTAssertEqual(ActivitySummary.plainText(for: neither), "1 message, ran 2 commands")
    }

    func testAccessibilityLabelSpellsTheMessagesAsEarlierAndTheFailureAsAFailedCall() {
        let expectedTime = ToolGroupSummary.durationText(seconds: 41)!

        XCTAssertEqual(ActivitySummary.accessibilityLabel(for: richRow()),
                       "3 earlier messages, ran 9 commands, read 2 files, +4 more, 1 failed call, \(expectedTime)")
    }

    func testAccessibilityLabelMatchesTheSpokenExample() {
        let g = group(0, bashes(9) + reads("a", "b"), failed: 1, start: 0, end: 41)
        let s = segment([message(0), message(1), .group(g)])
        let expectedTime = ToolGroupSummary.durationText(seconds: 41)!

        XCTAssertEqual(ActivitySummary.accessibilityLabel(for: s), "2 earlier messages, ran 9 commands, read 2 files, 1 failed call, \(expectedTime)")
    }

    func testAccessibilityLabelIsSingularForOneMessageAndPluralForSeveralFailures() {
        let one = segment([message(0), .group(group(0, bashes(2), failed: 1))])
        let several = segment([message(0), .group(group(0, bashes(3), failed: 3))])

        XCTAssertEqual(ActivitySummary.accessibilityLabel(for: one), "1 earlier message, ran 2 commands, 1 failed call")
        XCTAssertEqual(ActivitySummary.accessibilityLabel(for: several), "1 earlier message, ran 3 commands, 3 failed calls")
    }

    func testAccessibilityLabelOmitsWhatIsAbsent() {
        XCTAssertEqual(ActivitySummary.accessibilityLabel(for: segment(messages(2))), "2 earlier messages")
        XCTAssertEqual(ActivitySummary.accessibilityLabel(for: segment([message(0), .group(group(0, bashes(2)))])),
                       "1 earlier message, ran 2 commands")
    }

    func testAccessibilityLabelCountsTheMessagesPhraseTowardsTheCap() {
        let s = segment([message(0), message(1), .group(group(0, bashes(1) + reads("a") + edits(2) + [tool("Grep")]))])

        XCTAssertEqual(ActivitySummary.accessibilityLabel(for: s), "2 earlier messages, ran 1 command, read 1 file, +3 more")
    }

    func testAccessibilityLabelOfARowWithNoMessagesHasNoMessagesPhrase() {
        // Decision (reported to Cody): the label is built like the title, so the first phrase is capitalised.
        let s = segment([.group(group(0, bashes(2), failed: 1))])

        XCTAssertEqual(ActivitySummary.accessibilityLabel(for: s), "Ran 2 commands, 1 failed call")
    }

    // MARK: Copy Messages

    private func blockText(_ table: [Int: String]) -> (Int) -> String? { { table[$0] } }

    func testCopyMessagesIsTheFoldedMessagesInOrderWithABlankLineBetween() {
        let s = segment([message(0, [0]), .group(group(0, bashes(2))), message(1, [4]), .group(group(1, bashes(1))), message(2, [8])])

        let text = ActivitySummary.messagesText(for: s, blockText: blockText([0: "Alpha", 4: "Beta", 8: "Gamma"]))

        XCTAssertEqual(text, "Alpha\n\nBeta\n\nGamma")
    }

    func testCopyMessagesJoinsAMessagesOwnTextBlocksTheSameWayAndSkipsBlocksWithoutText() {
        let s = segment([message(0, [0, 1, 2]), .group(group(0, bashes(1))), message(1, [4])])

        let text = ActivitySummary.messagesText(for: s, blockText: blockText([0: "one", 2: "two", 4: "three"]))

        XCTAssertEqual(text, "one\n\ntwo\n\nthree")
    }

    func testCopyMessagesLeavesOutToolGroups() {
        let s = segment([.group(group(0, [tool("Bash", summary: "SECRET-COMMAND")])), message(0, [3])])

        let text = ActivitySummary.messagesText(for: s, blockText: blockText([0: "SECRET-COMMAND", 3: "hello"]))

        XCTAssertEqual(text, "hello")
    }

    func testCopyMessagesOfARowWithNoMessagesIsEmpty() {
        let s = segment([.group(group(0, bashes(2)))])

        XCTAssertEqual(ActivitySummary.messagesText(for: s, blockText: { _ in "never" }), "")
    }

    func testCopyMessagesKeepsTheTextExactlyAsItIsWithoutSanitizingOrTrimming() {
        for hostile in HostileContent.all + ["  padded \n", "\n\nleading and trailing\n\n"] {
            let s = segment([message(0, [0]), .group(group(0, bashes(1))), message(1, [2])])

            let text = ActivitySummary.messagesText(for: s, blockText: blockText([0: hostile, 2: "tail"]))

            XCTAssertTrue(Array(text.utf8) == Array((hostile + "\n\ntail").utf8), "hostile \(hostile.prefix(20))")
        }
    }

    // MARK: Copy Messages: only the assistant's own non-empty text

    private func textBlock(_ nonEmpty: Bool = true) -> FoldBlock { .prose(nonEmpty: nonEmpty) }
    private func sub(_ parent: String, nonEmpty: Bool = true) -> FoldBlock { .prose(nonEmpty: nonEmpty, parentId: parent) }
    private func bashCall(_ id: String) -> [FoldBlock] {
        [.toolCall(FoldCall(name: "Bash", toolUseId: id)), .toolResult(FoldResult(toolUseId: id))]
    }

    /// What a transcript adapter would supply: text for EVERY prose block (junk and subagent
    /// ones included), nil for anything else. Copy Messages must still pick only the right ones.
    private func everyProseBlockHasText(_ blocks: [FoldBlock], _ texts: [Int: String]) -> (Int) -> String? {
        { index in
            guard blocks.indices.contains(index), case .prose = blocks[index] else { return nil }
            return texts[index] ?? "UNEXPECTED-TEXT-OF-BLOCK-\(index)"
        }
    }

    /// The Copy Messages text of every activity row of the planned turn, in order.
    private func copiedMessages(_ blocks: [FoldBlock], _ texts: [Int: String]) -> [String] {
        let items = FocusPlanner.plan(blocks: blocks, outcome: .completedOk, turnKey: "T")
        let blockText = everyProseBlockHasText(blocks, texts)
        return items.compactMap { item in
            guard case .activity(let s) = item else { return nil }
            return ActivitySummary.messagesText(for: s, blockText: blockText)
        }
    }

    func testCopyMessagesSkipsWhitespaceOnlyTextBetweenTwoTextBlocksOfOneMessage() {
        let blocks: [FoldBlock] = [textBlock(), textBlock(false), textBlock(), textBlock(false)] + bashCall("a") + [textBlock()]
        // 0 "one", 1 whitespace, 2 "two", 3 whitespace (after the last text: not in the message), call, result, last

        let copied = copiedMessages(blocks, [0: "one", 1: " \n\t ", 2: "two", 3: "\n", 6: "last"])

        XCTAssertEqual(copied, ["one\n\ntwo"])
    }

    func testCopyMessagesHasNoBlankGapWhereJunkSitsAtTheEdgesOfMessages() {
        let blocks: [FoldBlock] = [textBlock(false), textBlock(), textBlock(false)] + bashCall("a")
            + [textBlock(false), textBlock(), textBlock(false), .hidden] + bashCall("b") + [textBlock()]
        // 0 junk, 1 "alpha", 2 junk, call 3, result 4, 5 junk, 6 "beta", 7 junk, 8 hidden, call 9, result 10, 11 last

        let copied = copiedMessages(blocks, [0: "  ", 1: "alpha", 2: "\n\n", 5: "\t", 6: "beta", 7: " ", 11: "last"])

        XCTAssertEqual(copied, ["alpha\n\nbeta"])
    }

    func testCopyMessagesKeepsWhatItKeepsExactlyAsItIsEvenWhenItLooksPadded() {
        let blocks: [FoldBlock] = [textBlock(), textBlock(false), textBlock()] + bashCall("a") + [textBlock()]

        let copied = copiedMessages(blocks, [0: "  padded \n", 1: "\n", 2: "\n\nalso padded\n\n", 5: "last"])

        XCTAssertEqual(copied, ["  padded \n" + "\n\n" + "\n\nalso padded\n\n"])
    }

    func testCopyMessagesLeavesOutHiddenBlocks() {
        let blocks: [FoldBlock] = [textBlock(), .hidden, textBlock()] + bashCall("a") + [textBlock()]

        XCTAssertEqual(copiedMessages(blocks, [0: "one", 2: "two", 5: "last"]), ["one\n\ntwo"])
    }

    func testCopyMessagesLeavesOutSubagentProseAttachedToAnAgentCallBetweenTheMessagesTextBlocks() {
        let blocks: [FoldBlock] = [.toolCall(FoldCall(name: "Agent", toolUseId: "a")), .toolResult(FoldResult(toolUseId: "a")),
                                   textBlock(), sub("a"), textBlock(), sub("a", nonEmpty: false), textBlock(false)]
            + bashCall("b") + [textBlock()]
        // call 0, result 1, "one" 2, subagent 3 (attached to Agent a), "two" 4, whitespace subagent 5, junk 6, call 7, result 8, last 9

        let copied = copiedMessages(blocks, [2: "one", 3: "SUBAGENT SAYS HI", 4: "two", 5: "  ", 6: " ", 9: "last"])

        XCTAssertEqual(copied, ["one\n\ntwo"])
        XCTAssertFalse(copied.joined().contains("SUBAGENT"))
    }

    func testCopyMessagesNeverIncludesAnOrphanSubagentProseWhichIsABoundaryNotAMessage() {
        let blocks: [FoldBlock] = [textBlock(), sub("?"), textBlock()] + bashCall("a") + [textBlock(), sub("nope")]
        // "before" 0, ORPHAN 1, "after" 2, call 3, result 4, "tail" 5, ORPHAN 6

        let copied = copiedMessages(blocks, [0: "before", 1: "ORPHAN ONE", 2: "after", 5: "tail", 6: "ORPHAN TWO"])

        XCTAssertEqual(copied, ["before", "after"], "each side of the orphan is its own row, and the orphan is in neither")
        XCTAssertFalse(copied.joined().contains("ORPHAN"))
    }

    func testCopyMessagesOfARowAcrossAnAttachedAndAnOrphanSubagentProseIsOnlyTheAssistantsOwnText() {
        let blocks: [FoldBlock] = [.toolCall(FoldCall(name: "Agent", toolUseId: "a"))]
            + [textBlock(), sub("a"), textBlock(false), textBlock()] + bashCall("b")
            + [textBlock(), sub("b"), textBlock()] + bashCall("c") + [textBlock()]
        // Agent 0, "m0a" 1, attached sub 2, junk 3, "m0b" 4, call 5, result 6, "m1" 7, sub "b" 8 (b is not an Agent: orphan), "m2" 9, ...

        let items = FocusPlanner.plan(blocks: blocks, outcome: .completedOk, turnKey: "T")
        let texts: [Int: String] = [1: "m0a", 2: "SUB-ATTACHED", 3: "  ", 4: "m0b", 7: "m1", 8: "SUB-ORPHAN", 9: "m2", 12: "last"]
        let blockText = everyProseBlockHasText(blocks, texts)

        let rows = items.compactMap { item -> String? in
            guard case .activity(let s) = item else { return nil }
            return ActivitySummary.messagesText(for: s, blockText: blockText)
        }
        XCTAssertEqual(rows.joined(separator: "|"), "m0a\n\nm0b\n\nm1|m2")
        XCTAssertFalse(rows.joined().contains("SUB-"))
    }

    func testCopyMessagesOfAMessageWithNothingButJunkContributesNothingNotEvenASeparator() {
        // The adapter said non-empty, but the text turns out to be whitespace-only: no blank gap,
        // no stray separator at either end or in the middle.
        let blocks: [FoldBlock] = [textBlock()] + bashCall("a") + [textBlock()] + bashCall("b") + [textBlock()] + bashCall("c") + [textBlock()]
        // m0 0, g0, m1 3 (junk), g1, m2 6, g2, latest 9

        let items = FocusPlanner.plan(blocks: blocks, outcome: .completedOk, turnKey: "T")
        guard case .activity(let s)? = items.first else { return XCTFail("expected a row, got \(items)") }
        let texts: [Int: String] = [0: "first", 3: " \n\u{00A0}\t", 6: "third", 9: "last"]

        XCTAssertEqual(ActivitySummary.messagesText(for: s, blockText: { texts[$0] }), "first\n\nthird")
        let junkFirst: [Int: String] = [0: "\n", 3: "keep", 6: "  ", 9: "last"]
        XCTAssertEqual(ActivitySummary.messagesText(for: s, blockText: { junkFirst[$0] }), "keep")
        let allJunk: [Int: String] = [0: "\n", 3: " ", 6: "\t "]
        XCTAssertEqual(ActivitySummary.messagesText(for: s, blockText: { allJunk[$0] }), "")
    }

    func testCopyMessagesTreatsUnicodeWhitespaceAsJunkLikeTheFoldRuleDoes() {
        let junk = ["\u{00A0}", "\u{2003}", "\u{3000}", "\r\n", "\u{2028}", "\t\t"]
        for text in junk {
            XCTAssertFalse(text.contains { !$0.isWhitespace }, "premise: \(text.unicodeScalars.map(\.value)) is whitespace-only to FoldBlock")
            let s = segment([message(0, [0, 1, 2])])
            XCTAssertEqual(ActivitySummary.messagesText(for: s, blockText: blockText([0: "a", 1: text, 2: "b"])), "a\n\nb",
                           "\(text.unicodeScalars.map(\.value))")
        }
    }

    func testCopyMessagesKeepsTextThatMerelyContainsWhitespaceAndInvisibleCharacters() {
        // Not whitespace-only by the fold rule: a zero-width space is not whitespace.
        let s = segment([message(0, [0, 1])])

        XCTAssertEqual(ActivitySummary.messagesText(for: s, blockText: blockText([0: "\u{200B}", 1: " x "])), "\u{200B}\n\n x ")
    }

    // MARK: Copy Commands

    private func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private func bash(_ command: String) -> FoldCall {
        tool("Bash", summary: "cmd", full: json(["command": command]))
    }

    func testCopyCommandsIsEachGroupsCommandsInOrderOneGroupAfterAnother() {
        let g0 = group(0, [bash("ls -la"), bash("pwd")])
        let g1 = group(1, [bash("git status")])
        let s = segment([message(0), .group(g0), message(1), .group(g1)])

        let text = ActivitySummary.commandsText(for: s, payloadAvailable: true)

        XCTAssertEqual(text, "ls -la\npwd\ngit status")
        XCTAssertEqual(text, [ToolGroupSummary.commandsText(for: g0, payloadAvailable: true),
                              ToolGroupSummary.commandsText(for: g1, payloadAvailable: true)].joined(separator: "\n"))
    }

    func testCopyCommandsLeavesOutTheMessages() {
        let s = segment([message(0, [0]), .group(group(0, [bash("echo hi")]))])

        XCTAssertEqual(ActivitySummary.commandsText(for: s, payloadAvailable: true), "echo hi")
    }

    func testCopyCommandsOfARowWithNoGroupsIsEmpty() {
        XCTAssertEqual(ActivitySummary.commandsText(for: segment(messages(2)), payloadAvailable: true), "")
    }

    func testCopyCommandsKeepsHostileCommandsByteForByte() {
        for hostile in HostileContent.all {
            let s = segment([.group(group(0, [bash(hostile)])), message(0), .group(group(1, [bash("after")]))])

            let text = ActivitySummary.commandsText(for: s, payloadAvailable: true)

            XCTAssertTrue(Array(text.utf8) == Array((hostile + "\nafter").utf8), "hostile \(hostile.prefix(20))")
        }
    }

    func testCopyCommandsFollowsEachGroupsTruncationNoteWhenThePayloadIsGone() {
        let dropped = FoldCall(name: "Bash", inputSummary: "ls", inputFull: "")
        let g0 = group(0, [dropped])
        let g1 = group(1, [bash("pwd")])
        let s = segment([.group(g0), message(0), .group(g1)])

        let text = ActivitySummary.commandsText(for: s, payloadAvailable: false)

        XCTAssertEqual(text, [ToolGroupSummary.commandsText(for: g0, payloadAvailable: false),
                              ToolGroupSummary.commandsText(for: g1, payloadAvailable: false)].joined(separator: "\n"))
        XCTAssertTrue(text.contains(ToolGroupSummary.truncatedCommandsNote))
    }
}
