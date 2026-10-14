import XCTest
import NostromoKit

/// The words on a group row (PRD "Summary grammar", "The group row (collapsed)") and the
/// two copy texts. Groups come from `ToolFoldPlanner.plan`; a `ToolGroup` has no public
/// way to fill it in by hand.
final class ToolGroupSummaryTests: XCTestCase {

    // MARK: Builders

    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }

    private func tool(_ name: String, target: String? = nil, summary: String = "", full: String = "") -> FoldCall {
        FoldCall(name: name, target: target, inputSummary: summary, inputFull: full)
    }

    private func tools(_ names: String...) -> [FoldCall] { names.map { tool($0) } }

    /// A settled group of `calls`, each with a result. The first `failed` results are errors.
    /// `start` stamps calls that have no start time, `end` stamps every result.
    private func group(_ calls: [FoldCall], failed: Int = 0, start: Double? = nil, end: Double? = nil,
                       file: StaticString = #filePath, line: UInt = #line) -> ToolGroup {
        var blocks: [FoldBlock] = []
        for (index, original) in calls.enumerated() {
            var call = original
            if call.toolUseId == nil { call.toolUseId = "c\(index)" }
            if call.startedAt == nil, let start { call.startedAt = at(start) }
            blocks.append(.toolCall(call))
            blocks.append(.toolResult(FoldResult(toolUseId: call.toolUseId, isError: index < failed, at: end.map(at))))
        }
        return onlyGroup(blocks, file: file, line: line)
    }

    private func onlyGroup(_ blocks: [FoldBlock], file: StaticString = #filePath, line: UInt = #line) -> ToolGroup {
        let items = ToolFoldPlanner.plan(blocks: blocks, outcome: .completedOk, turnKey: "T")
        guard items.count == 1, case .group(let g) = items[0] else {
            XCTFail("expected exactly one group, got \(items)", file: file, line: line)
            return ToolGroup(id: 0, key: "")
        }
        return g
    }

    private func summary(_ calls: [FoldCall], file: StaticString = #filePath, line: UInt = #line) -> String? {
        ToolGroupSummary.summary(for: group(calls, file: file, line: line))
    }

    private func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    private func bash(_ command: String, summary: String = "cmd") -> FoldCall {
        tool("Bash", summary: summary, full: json(["command": command]))
    }

    private func sameBytes(_ a: String, _ b: String) -> Bool { Array(a.utf8) == Array(b.utf8) }

    // MARK: Summary grammar

    func testThreeBashTwoReadsOfOneFileAndOneEditReadAsThePRDExample() {
        let calls = [tool("Edit", target: "b.swift"), tool("Read", target: "a.swift"), tool("Bash", summary: "ls"),
                     tool("Read", target: "a.swift"), tool("Bash", summary: "pwd"), tool("Bash", summary: "date")]

        XCTAssertEqual(summary(calls), "Ran 3 commands, read 1 file, edited 1 file")
    }

    func testReadsOfDistinctFilesAreCountedPerFile() {
        let calls = [tool("Bash"), tool("Read", target: "a.swift"), tool("Read", target: "b.swift"), tool("Read", target: "a.swift")]

        XCTAssertEqual(summary(calls), "Ran 1 command, read 2 files")
    }

    func testEditsAcrossWriteEditMultiEditAndNotebookEditCountDistinctFilesTogether() {
        let calls = [tool("Write", target: "a.swift"), tool("Edit", target: "a.swift"),
                     tool("MultiEdit", target: "b.swift"), tool("NotebookEdit", target: "c.ipynb"), tool("Bash")]

        XCTAssertEqual(summary(calls), "Ran 1 command, edited 3 files")
    }

    func testDistinctFilesFallBackToTheInputSummaryWhenThereIsNoTarget() {
        let calls = [tool("Bash"), tool("Read", summary: "a.swift"), tool("Read", summary: "b.swift"), tool("Read", summary: "a.swift")]

        XCTAssertEqual(summary(calls), "Ran 1 command, read 2 files")
    }

    func testAFileCallWithNeitherTargetNorSummaryDropsTheNumberOfThatPhrase() {
        let reads = [tool("Bash"), tool("Read", target: "a.swift"), tool("Read")]
        let edits = [tool("Bash"), tool("Edit", target: "a.swift"), tool("Write", target: nil, summary: "")]

        XCTAssertEqual(summary(reads), "Ran 1 command, read files")
        XCTAssertEqual(summary(edits), "Ran 1 command, edited files")
    }

    func testAnUnknownFileCountIsNeverShownAsZero() {
        let s = summary([tool("Read"), tool("Read")])

        XCTAssertEqual(s, "Read files")
    }

    func testMoreThanThreePhrasesShowThreeThenPlusTheNumberOfHiddenCalls() {
        let calls = [tool("Bash", summary: "ls"), tool("Read", target: "a"), tool("Edit", target: "b"),
                     tool("Grep"), tool("Grep"), tool("WebFetch"), tool("WebFetch"), tool("WebFetch")]

        XCTAssertEqual(summary(calls), "Ran 1 command, read 1 file, edited 1 file, +5 more")
    }

    func testHiddenCallsOfAPhraseWithoutACountStillCountTowardsMore() {
        let calls = [tool("Bash"), tool("Read", target: "a"), tool("Edit", target: "b"),
                     tool("TodoWrite"), tool("TodoWrite"), tool("TodoWrite")]

        XCTAssertEqual(summary(calls), "Ran 1 command, read 1 file, edited 1 file, +3 more")
    }

    func testExactlyThreePhrasesHaveNoMore() {
        XCTAssertEqual(summary([tool("Bash"), tool("Read", target: "a"), tool("Grep")]),
                       "Ran 1 command, read 1 file, searched 1 time")
    }

    func testPhrasesFollowTheFixedOrderWhateverTheCallOrder() {
        // Nine kinds, in reverse of the fixed order: Bash, Read and edits still lead.
        let calls = [tool("FrobnicateWidget"), tool("mcp__nostromo__x"), tool("TodoWrite"), tool("Agent"), tool("WebFetch"),
                     tool("Grep"), tool("Edit", target: "e"), tool("Read", target: "r"), tool("Bash")]

        XCTAssertEqual(summary(calls), "Ran 1 command, read 1 file, edited 1 file, +6 more")
    }

    func testTheLaterPhrasesFollowTheFixedOrderToo() {
        XCTAssertEqual(summary([tool("FrobnicateWidget"), tool("mcp__nostromo__x"), tool("TodoWrite")]),
                       "Updated todos, used 1 nostromo tool, used 1 other tool")
        XCTAssertEqual(summary([tool("Agent"), tool("WebFetch"), tool("Grep")]),
                       "Searched 1 time, fetched 1 page, ran 1 agent")
    }

    func testThreeToolsOfOneMCPServerReadAsUsedThreeServerTools() {
        XCTAssertEqual(summary([tool("mcp__nostromo__x"), tool("mcp__nostromo__y"), tool("mcp__nostromo__x")]),
                       "Used 3 nostromo tools")
    }

    func testAnMCPToolAlongsideBashIsItsOwnPhrase() {
        XCTAssertEqual(summary([tool("mcp__nostromo__a"), tool("Bash")]), "Ran 1 command, used 1 nostromo tool")
    }

    func testEachMCPServerGetsOnePhraseInFirstAppearanceOrder() {
        let calls = [tool("mcp__b__x"), tool("mcp__a__y"), tool("mcp__b__z")]

        XCTAssertEqual(summary(calls), "Used 2 b tools, used 1 a tool")
    }

    func testTheMCPServerIsTheTextBetweenMcpAndTheNextDoubleUnderscore() {
        let calls = [tool("mcp__claude_ai_Atlassian__getJiraIssue"), tool("mcp__claude_ai_Atlassian__search__deep")]

        XCTAssertEqual(summary(calls), "Used 2 claude_ai_Atlassian tools")
    }

    func testPluralPhrases() {
        XCTAssertEqual(summary([tool("Bash"), tool("Bash")]), "Ran 2 commands")
        XCTAssertEqual(summary([tool("Bash"), tool("Read", target: "a"), tool("Read", target: "b")]), "Ran 1 command, read 2 files")
        XCTAssertEqual(summary([tool("Bash"), tool("Grep"), tool("Glob")]), "Ran 1 command, searched 2 times")
        XCTAssertEqual(summary([tool("Bash"), tool("WebFetch"), tool("WebFetch")]), "Ran 1 command, fetched 2 pages")
        XCTAssertEqual(summary([tool("Bash"), tool("Agent"), tool("Agent")]), "Ran 1 command, ran 2 agents")
        XCTAssertEqual(summary([tool("Bash"), tool("FrobnicateWidget"), tool("NotebookRead")]), "Ran 1 command, used 2 other tools")
    }

    func testSingularPhrases() {
        XCTAssertEqual(summary([tool("Grep"), tool("Bash")]), "Ran 1 command, searched 1 time")
        XCTAssertEqual(summary([tool("Bash"), tool("Read", target: "a.swift")]), "Ran 1 command, read 1 file")
        XCTAssertEqual(summary([tool("Bash"), tool("Edit", target: "a.swift")]), "Ran 1 command, edited 1 file")
        XCTAssertEqual(summary([tool("Bash"), tool("Grep")]), "Ran 1 command, searched 1 time")
        XCTAssertEqual(summary([tool("Bash"), tool("WebSearch")]), "Ran 1 command, fetched 1 page")
        XCTAssertEqual(summary([tool("Bash"), tool("Task")]), "Ran 1 command, ran 1 agent")
        XCTAssertEqual(summary([tool("Bash"), tool("FrobnicateWidget")]), "Ran 1 command, used 1 other tool")
    }

    func testTodoWriteReadsAsUpdatedTodosWithNoCount() {
        XCTAssertEqual(summary([tool("Bash"), tool("TodoWrite")]), "Ran 1 command, updated todos")
        XCTAssertEqual(summary([tool("Bash"), tool("TodoWrite"), tool("TodoWrite"), tool("TodoWrite")]), "Ran 1 command, updated todos")
    }

    func testTaskAndAgentBothCountAsAgents() {
        XCTAssertEqual(summary([tool("Task"), tool("Agent")]), "Ran 2 agents")
    }

    func testWebSearchAndWebFetchBothCountAsPages() {
        XCTAssertEqual(summary([tool("WebSearch"), tool("WebFetch")]), "Fetched 2 pages")
    }

    func testGrepAndGlobBothCountAsSearches() {
        XCTAssertEqual(summary([tool("Grep"), tool("Glob")]), "Searched 2 times")
    }

    func testAnyOtherToolIsUsedNOtherTools() {
        XCTAssertEqual(summary([tool("FrobnicateWidget"), tool("NotebookRead"), tool("FrobnicateWidget")]), "Used 3 other tools")
    }

    func testAGroupOfOneHasNoSummarySoItsRowShowsTheCallHeader() {
        for name in ["Bash", "Read", "TodoWrite", "mcp__nostromo__x", "FrobnicateWidget"] {
            XCTAssertNil(summary([tool(name, target: "a")]), name)
        }
    }

    func testTheFirstPhraseIsCapitalisedAndTheRestAreNot() throws {
        let s = try XCTUnwrap(summary([tool("Grep"), tool("Bash")]))

        XCTAssertEqual(s, "Ran 1 command, searched 1 time")
        XCTAssertEqual(s.first, "R")
    }

    func testNoSummaryEverStatesAZeroCount() {
        let kinds = ["Bash", "Read", "Edit", "Grep", "WebFetch", "Agent", "TodoWrite", "mcp__nostromo__x", "FrobnicateWidget"]
        for mask in 1 ..< (1 << kinds.count) {
            // No targets and no summaries: every file count is unknowable.
            var calls = kinds.enumerated().filter { mask & (1 << $0.offset) != 0 }.map { tool($0.element) }
            calls.append(calls[0])
            let s = summary(calls) ?? ""
            XCTAssertFalse(s.contains(" 0 "), s)
            XCTAssertFalse(s.hasPrefix("0 "), s)
            XCTAssertFalse(s.isEmpty)
        }
    }

    func testSixtyDistinctMCPServersReadAsThreePhrasesAndFiftySevenMore() {
        let calls = HostileContent.mcpToolNames.map { tool($0) }

        XCTAssertEqual(calls.count, 60)
        XCTAssertEqual(summary(calls), "Used 1 server0 tool, used 1 server1 tool, used 1 server2 tool, +57 more")
    }

    // MARK: Header

    func testACallHeaderIsToolNameDotInputSummary() {
        let header = ToolGroupSummary.header(for: FoldCall(name: "Bash", inputSummary: "cargo test --workspace"))

        XCTAssertEqual(header, "Bash · cargo test --workspace")
    }

    func testAHeaderBuiltFromHostileTextIsSafeToDrawOnOneLine() {
        for hostile in HostileContent.all {
            let header = ToolGroupSummary.header(for: FoldCall(name: "Bash", inputSummary: hostile))

            XCTAssertFalse(header.unicodeScalars.contains(where: HostileContent.isForbiddenOnARow))
            XCTAssertTrue(header.hasPrefix("Bash"))
            XCTAssertLessThanOrEqual(header.utf16.count, FoldTextSanitizer.maxUTF16 + "Bash · ".utf16.count)
        }
    }

    // MARK: Failures

    func testFailureTextCountsTopLevelFailures() {
        let calls = tools("Bash", "Bash", "Bash", "Read")

        XCTAssertEqual(ToolGroupSummary.failureText(for: group(calls, failed: 1)), "1 failed")
        XCTAssertEqual(ToolGroupSummary.failureText(for: group(calls, failed: 3)), "3 failed")
    }

    func testFailureTextIsNilWhenNothingFailed() {
        XCTAssertNil(ToolGroupSummary.failureText(for: group(tools("Bash", "Bash"))))
    }

    // MARK: Durations

    func testDurationTextFormats() {
        XCTAssertEqual(ToolGroupSummary.durationText(seconds: 0.85), "850 ms")
        XCTAssertEqual(ToolGroupSummary.durationText(seconds: 4.1), "4.1 s")
        XCTAssertEqual(ToolGroupSummary.durationText(seconds: 4.14), "4.1 s")
        XCTAssertEqual(ToolGroupSummary.durationText(seconds: 59.94), "59.9 s")
        XCTAssertEqual(ToolGroupSummary.durationText(seconds: 60), "1 m 00 s")
        XCTAssertEqual(ToolGroupSummary.durationText(seconds: 125), "2 m 05 s")
        XCTAssertEqual(ToolGroupSummary.durationText(seconds: 3600), "1 h 00 m")
        XCTAssertEqual(ToolGroupSummary.durationText(seconds: 3720), "1 h 02 m")
    }

    func testDurationTextBelowOneMillisecondIsNilNeverZeroMs() {
        XCTAssertNil(ToolGroupSummary.durationText(seconds: 0))
        XCTAssertNil(ToolGroupSummary.durationText(seconds: 0.0004))
        XCTAssertEqual(ToolGroupSummary.durationText(seconds: 0.001), "1 ms")
    }

    func testDurationRoundingCarriesIntoTheNextUnit() {
        XCTAssertEqual(ToolGroupSummary.durationText(seconds: 0.9996), "1.0 s")
        XCTAssertEqual(ToolGroupSummary.durationText(seconds: 59.96), "1 m 00 s")
    }

    func testGroupDurationIsTheSpanFromFirstStartToLastEnd() {
        let g = group(tools("Bash", "Bash", "Bash"), start: 0, end: 4.1)

        XCTAssertEqual(ToolGroupSummary.durationText(for: g), "4.1 s")
    }

    func testGroupDurationIsNilWhenTheStartIsUnknown() {
        XCTAssertNil(ToolGroupSummary.durationText(for: group(tools("Bash", "Bash"), start: nil, end: 4.1)))
    }

    func testGroupDurationIsNilWhenTheEndIsUnknown() {
        XCTAssertNil(ToolGroupSummary.durationText(for: group(tools("Bash", "Bash"), start: 0, end: nil)))
    }

    func testAGroupWhoseStartEqualsItsEndHasNoDurationRatherThanZeroMs() {
        XCTAssertNil(ToolGroupSummary.durationText(for: group(tools("Bash", "Bash"), start: 5, end: 5)))
    }

    // MARK: Plain text and VoiceOver label

    private func readFileThreeBashOneFailedFourPointOneSeconds() -> ToolGroup {
        group([tool("Bash"), tool("Bash"), tool("Bash"), tool("Read", target: "a.swift")], failed: 1, start: 0, end: 4.1)
    }

    func testPlainTextJoinsSummaryFailureAndTimeWithMiddleDots() {
        XCTAssertEqual(ToolGroupSummary.plainText(for: readFileThreeBashOneFailedFourPointOneSeconds()),
                       "Ran 3 commands, read 1 file · 1 failed · 4.1 s")
    }

    func testPlainTextSkipsPartsThatAreAbsent() {
        let clean = group([tool("Bash"), tool("Bash"), tool("Bash"), tool("Read", target: "a.swift")])
        let failedOnly = group([tool("Bash"), tool("Bash"), tool("Bash"), tool("Read", target: "a.swift")], failed: 1)
        let timedOnly = group([tool("Bash"), tool("Bash"), tool("Bash"), tool("Read", target: "a.swift")], start: 0, end: 4.1)

        XCTAssertEqual(ToolGroupSummary.plainText(for: clean), "Ran 3 commands, read 1 file")
        XCTAssertEqual(ToolGroupSummary.plainText(for: failedOnly), "Ran 3 commands, read 1 file · 1 failed")
        XCTAssertEqual(ToolGroupSummary.plainText(for: timedOnly), "Ran 3 commands, read 1 file · 4.1 s")
    }

    func testPlainTextOfAGroupOfOneIsTheCallHeaderThenTime() {
        let g = group([tool("Bash", summary: "cargo test")], start: 0, end: 3.2)

        XCTAssertEqual(ToolGroupSummary.plainText(for: g), "Bash · cargo test · 3.2 s")
    }

    func testPlainTextOfAFailedGroupOfOneCarriesTheFailureBeforeTheTime() {
        let g = group([tool("Bash", summary: "cargo test")], failed: 1, start: 0, end: 3.2)

        XCTAssertEqual(ToolGroupSummary.plainText(for: g), "Bash · cargo test · 1 failed · 3.2 s")
    }

    func testAccessibilityLabelSpellsTheFailureAsAFailedCall() {
        XCTAssertEqual(ToolGroupSummary.accessibilityLabel(for: readFileThreeBashOneFailedFourPointOneSeconds()),
                       "Ran 3 commands, read 1 file, 1 failed call, 4.1 s")
    }

    func testAccessibilityLabelPluralisesFailedCalls() {
        let g = group(tools("Bash", "Bash", "Bash"), failed: 2, start: 0, end: 4.1)

        XCTAssertEqual(ToolGroupSummary.accessibilityLabel(for: g), "Ran 3 commands, 2 failed calls, 4.1 s")
    }

    func testAccessibilityLabelOmitsAbsentParts() {
        let g = group(tools("Bash", "Bash", "Grep"))

        XCTAssertEqual(ToolGroupSummary.accessibilityLabel(for: g), "Ran 2 commands, searched 1 time")
    }

    func testAccessibilityLabelOfAFailedGroupOfOneNamesTheCallTheFailureAndTheTime() {
        let g = group([tool("Bash", summary: "cargo test")], failed: 1, start: 0, end: 3.2)

        let label = ToolGroupSummary.accessibilityLabel(for: g)

        XCTAssertTrue(label.hasPrefix("Bash"), label)
        XCTAssertTrue(label.contains("cargo test"), label)
        XCTAssertTrue(label.contains("1 failed call"), label)
        XCTAssertTrue(label.contains("3.2 s"), label)
    }

    // MARK: Copy Commands

    func testBashCommandsAreCopiedVerbatimIncludingNewlinesAndLongLines() {
        let multiLine = "set -e\ncargo build \\\n  --release\necho \"done\""
        let long = "echo " + String(repeating: "a long argument ", count: 20)
        let g = group([bash(multiLine), bash(long)])

        let text = ToolGroupSummary.commandsText(for: g, payloadAvailable: true)

        XCTAssertGreaterThan(long.count, 80)
        XCTAssertEqual(text, multiLine + "\n" + long)
    }

    func testHostileBashCommandsAreCopiedByteForByteUnsanitized() {
        for hostile in HostileContent.all {
            let g = group([bash(hostile)])

            let text = ToolGroupSummary.commandsText(for: g, payloadAvailable: true)

            XCTAssertTrue(sameBytes(text, hostile), "a hostile command must copy verbatim (\(hostile.utf8.count) bytes)")
        }
    }

    func testTheTenThousandCharacterCommandIsNotCut() {
        let text = ToolGroupSummary.commandsText(for: group([bash(HostileContent.longCommand)]), payloadAvailable: true)

        XCTAssertEqual(text.count, 10_000)
    }

    func testOtherToolsCopyAsNameThenTheirInputOnOneLine() {
        let input = json(["file_path": "a.swift", "old_string": "foo", "new_string": "bar baz"])
        let g = group([tool("Edit", target: "a.swift", summary: "a.swift", full: input)])

        let text = ToolGroupSummary.commandsText(for: g, payloadAvailable: true)

        XCTAssertFalse(text.contains("\n"), "the input is compacted onto one line: \(text)")
        XCTAssertTrue(text.hasPrefix("Edit "), text)
        for value in ["a.swift", "foo", "bar baz"] { XCTAssertTrue(text.contains(value), "\(value) in \(text)") }
    }

    func testCommandsAreOnePerLineInCallOrder() {
        let edit = json(["file_path": "a.swift", "new_string": "x"])
        let g = group([bash("first"), tool("Edit", full: edit), bash("third")])

        let lines = ToolGroupSummary.commandsText(for: g, payloadAvailable: true).components(separatedBy: "\n")

        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines[0], "first")
        XCTAssertTrue(lines[1].hasPrefix("Edit "), lines[1])
        XCTAssertEqual(lines[2], "third")
    }

    func testCommandsLeaveOutTheSubagentsOwnCalls() {
        let blocks: [FoldBlock] = [
            .toolCall(FoldCall(name: "Bash", toolUseId: "b1", inputSummary: "s", inputFull: json(["command": "outer-one"]))),
            .toolCall(FoldCall(name: "Agent", toolUseId: "A", inputSummary: "s", inputFull: json(["prompt": "dig"]))),
            .toolCall(FoldCall(name: "Bash", toolUseId: "s1", parentId: "A", inputSummary: "s", inputFull: json(["command": "inner-secret"]))),
            .toolResult(FoldResult(toolUseId: "s1", parentId: "A")),
            .toolResult(FoldResult(toolUseId: "A")),
            .toolCall(FoldCall(name: "Bash", toolUseId: "b2", inputSummary: "s", inputFull: json(["command": "outer-two"]))),
        ]

        let text = ToolGroupSummary.commandsText(for: onlyGroup(blocks), payloadAvailable: true)
        let lines = text.components(separatedBy: "\n")

        XCTAssertFalse(text.contains("inner-secret"))
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(lines.first, "outer-one")
        XCTAssertTrue(lines[1].hasPrefix("Agent "), lines[1])
        XCTAssertEqual(lines.last, "outer-two")
    }

    func testADroppedPayloadCopiesTheSummaryWithAnEllipsisAndAFinalTruncationNote() {
        let g = group([tool("Bash", summary: "cargo test --workspace"), tool("Edit", summary: "a.swift")])

        let text = ToolGroupSummary.commandsText(for: g, payloadAvailable: false)

        XCTAssertEqual(text, "cargo test --workspace …\nEdit a.swift …\n" + ToolGroupSummary.truncatedCommandsNote)
        XCTAssertEqual(text.components(separatedBy: "\n").last, ToolGroupSummary.truncatedCommandsNote)
    }

    func testCallsWhosePayloadSurvivedStillCopyInFullBesideDroppedOnes() {
        let g = group([bash("kept command"), tool("Bash", summary: "gone command")])

        let text = ToolGroupSummary.commandsText(for: g, payloadAvailable: false)

        XCTAssertEqual(text, "kept command\ngone command …\n" + ToolGroupSummary.truncatedCommandsNote)
    }

    func testNoTruncationNoteWhenEveryPayloadIsStillThere() {
        let g = group([bash("one"), bash("two")])

        XCTAssertEqual(ToolGroupSummary.commandsText(for: g, payloadAvailable: false), "one\ntwo")
        XCTAssertEqual(ToolGroupSummary.commandsText(for: g, payloadAvailable: true), "one\ntwo")
    }

    func testNoTruncationNoteWhenThePayloadIsAvailable() {
        let g = group([bash("one"), tool("Bash", summary: "no input recorded")])

        XCTAssertFalse(ToolGroupSummary.commandsText(for: g, payloadAvailable: true).contains(ToolGroupSummary.truncatedCommandsNote))
    }
}

/// Review follow-ups (Perri, TF2).
final class ToolGroupCommandsEdgeTests: XCTestCase {

    private func group(_ calls: [FoldCall]) -> ToolGroup {
        let blocks = calls.map { FoldBlock.toolCall($0) }
        guard case .group(let g)? = ToolFoldPlanner.plan(blocks: blocks, outcome: .completedOk, turnKey: "t").first
        else { fatalError("no group") }
        return g
    }

    func testABashInputThatIsNotJSONCopiesAsSentNotTheSummary() {
        let g = group([FoldCall(name: "Bash", inputSummary: "make te…", inputFull: "make test && make lint")])
        XCTAssertEqual(ToolGroupSummary.commandsText(for: g, payloadAvailable: true), "make test && make lint")
    }

    func testAnotherToolsInputKeepsItsKeyOrderAndNumbersOnOneLine() {
        let full = "{\n  \"zeta\" : 1.50,\n  \"alpha\" : \"a\\nb\"\n}"
        let g = group([FoldCall(name: "Frob", inputSummary: "x", inputFull: full)])
        XCTAssertEqual(ToolGroupSummary.commandsText(for: g, payloadAvailable: true),
                       "Frob { \"zeta\" : 1.50, \"alpha\" : \"a\\nb\" }")
    }
}

final class ToolFoldPlannerQuietCallTests: XCTestCase {

    func testAQuietCallWithoutATimeIsFinishedButHasNoEnd() {
        let quiet = FoldCall(name: "Bash", toolUseId: "a", startedAt: Date(timeIntervalSince1970: 0),
                             finishedQuietly: true, inputSummary: "mkdir x")
        let items = ToolFoldPlanner.plan(blocks: [.toolCall(quiet)], outcome: .open, turnKey: "t")
        guard case .group(let g)? = items.first else { return XCTFail("no group") }
        XCTAssertEqual(g.finishedCount, 1)
        XCTAssertEqual(g.state, .settled)
        XCTAssertNil(g.endedAt)
    }

    func testSubagentBlocksDoNotAttachToAnAgentThatFinishedQuietly() {
        let agent = FoldCall(name: "Agent", toolUseId: "ag", finishedQuietly: true, inputSummary: "survey")
        let inner = FoldCall(name: "Read", toolUseId: "r", parentId: "?", inputSummary: "a.swift")
        let items = ToolFoldPlanner.plan(blocks: [.toolCall(agent), .toolCall(inner)], outcome: .open, turnKey: "t")
        guard case .group(let g)? = items.first else { return XCTFail("no group") }
        XCTAssertTrue(g.subagentBlocks.isEmpty, "nowhere to attach: the inner call falls back to a member")
        XCTAssertEqual(g.callCount, 2)
    }

    func testTheWireMappingMarksAQuietResultWithoutATimeFinished() {
        let blocks = FoldBlock.blocks(from: [
            .toolCall(toolName: "Bash", inputSummary: "mkdir x", inputFull: "{}", meta: DaemonToolMeta(toolUseId: "a")),
            .toolResult(content: "", isError: false, meta: DaemonToolMeta(toolUseId: "a")),
        ])
        guard case .toolCall(let call) = blocks[0] else { return XCTFail("not a call") }
        XCTAssertTrue(call.finishedQuietly)
        XCTAssertNil(call.finishedAt)
        XCTAssertEqual(blocks[1], .hidden)
    }
}
