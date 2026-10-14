import XCTest
import NostromoKit

/// How daemon wire blocks become fold input (`FoldBlock.blocks(from:)`, `FoldOutcome.of`).
final class FoldBlockAdapterTests: XCTestCase {

    private typealias Block = [String: Any]

    private func decodeTurn(complete: Bool = true, _ blocks: [Block]) throws -> DaemonTurn {
        let object: Block = ["id": "t1", "user_input": "go", "timestamp": "2026-01-01T00:00:00Z",
                             "blocks": blocks, "is_complete": complete]
        return try JSONDecoder().decode(DaemonTurn.self, from: JSONSerialization.data(withJSONObject: object))
    }

    private func fold(_ blocks: [Block]) throws -> [FoldBlock] {
        FoldBlock.blocks(from: try decodeTurn(blocks).blocks)
    }

    private let base = 1_767_225_600.0   // 2026-01-01T00:00:00Z

    private func text(_ s: String, parent: String? = nil) -> Block {
        var b: Block = ["kind": "text", "text": s]
        if let parent { b["parent_tool_use_id"] = parent }
        return b
    }

    private func toolCall(_ name: String = "Bash", id: String? = nil, parent: String? = nil, target: String? = nil,
                          ts: String? = nil, summary: String = "s", full: String = "{}") -> Block {
        var b: Block = ["kind": "tool_call", "tool_name": name, "input_summary": summary, "input_full": full]
        if let id { b["tool_use_id"] = id }
        if let parent { b["parent_tool_use_id"] = parent }
        if let target { b["target"] = target }
        if let ts { b["ts"] = ts }
        return b
    }

    private func toolResult(_ content: String = "ok", id: String? = nil, error: Bool = false, parent: String? = nil, ts: String? = nil) -> Block {
        var b: Block = ["kind": "tool_result", "content": content, "is_error": error]
        if let id { b["tool_use_id"] = id }
        if let parent { b["parent_tool_use_id"] = parent }
        if let ts { b["ts"] = ts }
        return b
    }

    // MARK: Blocks

    func testWhitespaceOnlyTextIsEmptyProseAndOtherTextIsNonEmpty() throws {
        let folded = try fold([text("hello"), text("  \n\t "), text("")])

        XCTAssertEqual(folded, [.prose(nonEmpty: true), .prose(nonEmpty: false), .prose(nonEmpty: false)])
    }

    func testSubagentTextKeepsItsParentId() throws {
        XCTAssertEqual(try fold([text("inner", parent: "A")]), [.prose(nonEmpty: true, parentId: "A")])
    }

    func testAToolCallCarriesItsIdentityTargetStartAndInputs() throws {
        let folded = try fold([toolCall("Read", id: "toolu_1", parent: "A", target: "a.swift",
                                        ts: "2026-01-01T00:00:01.500Z", summary: "a.swift", full: "{\"file_path\":\"a.swift\"}")])

        XCTAssertEqual(folded, [.toolCall(FoldCall(
            name: "Read", toolUseId: "toolu_1", parentId: "A", target: "a.swift",
            startedAt: Date(timeIntervalSince1970: base + 1.5), finishedAt: nil,
            inputSummary: "a.swift", inputFull: "{\"file_path\":\"a.swift\"}"))])
    }

    func testAToolResultCarriesItsIdErrorFlagAndArrivalTime() throws {
        let folded = try fold([toolResult("boom", id: "toolu_1", error: true, parent: "A", ts: "2026-01-01T00:00:03Z")])

        XCTAssertEqual(folded, [.toolResult(FoldResult(toolUseId: "toolu_1", parentId: "A", isError: true,
                                                       at: Date(timeIntervalSince1970: base + 3)))])
    }

    func testBlocksFromAnOlderDaemonHaveNoIdsOrTimes() throws {
        let folded = try fold([toolCall("Bash"), toolResult("out")])

        XCTAssertEqual(folded, [.toolCall(FoldCall(name: "Bash", inputSummary: "s", inputFull: "{}")),
                                .toolResult(FoldResult())])
    }

    func testEveryNonToolBlockKindMapsToItsBoundary() throws {
        let folded = try fold([
            ["kind": "ask_question", "question": "q", "header": "h", "options": [], "multi_select": false],
            ["kind": "error_message", "message": "oops"],
            ["kind": "note", "note_kind": "model_changed", "text": "Model changed"],
            ["kind": "result_summary", "duration_ms": 5, "cost_usd": 0.1, "is_error": false],
        ])

        XCTAssertEqual(folded, [.boundary(.askQuestion), .boundary(.errorMessage), .boundary(.note), .boundary(.resultSummary)])
    }

    // MARK: Quiet success

    func testAnEmptySuccessfulResultIsHiddenAndFinishesItsCall() throws {
        let folded = try fold([toolCall("Bash", id: "q", ts: "2026-01-01T00:00:01Z"),
                               toolResult("", id: "q", ts: "2026-01-01T00:00:02Z")])

        XCTAssertEqual(folded.count, 2, "indices stay parallel to the wire blocks")
        XCTAssertEqual(folded[1], .hidden)
        guard case .toolCall(let call) = folded[0] else { return XCTFail("not a call: \(folded[0])") }
        XCTAssertEqual(call.finishedAt, Date(timeIntervalSince1970: base + 2))
    }

    func testAnEmptyResultThatIsAnErrorIsStillAResult() throws {
        let folded = try fold([toolCall("Bash", id: "q"), toolResult("", id: "q", error: true)])

        guard case .toolResult(let r) = folded[1] else { return XCTFail("hidden an error: \(folded[1])") }
        XCTAssertTrue(r.isError)
    }

    func testAResultWithContentIsNotHidden() throws {
        let folded = try fold([toolCall("Bash", id: "q"), toolResult("done", id: "q")])

        XCTAssertNotEqual(folded[1], .hidden)
    }

    func testAHiddenQuietResultNeitherSplitsNorShrinksAGroup() throws {
        let folded = try fold([toolCall("Bash", id: "a", ts: "2026-01-01T00:00:01Z"), toolResult("", id: "a", ts: "2026-01-01T00:00:02Z"),
                               toolCall("Bash", id: "b", ts: "2026-01-01T00:00:03Z"), toolResult("x", id: "b", ts: "2026-01-01T00:00:04Z")])

        let items = ToolFoldPlanner.plan(blocks: folded, outcome: .open, turnKey: "t1")

        guard items.count == 1, case .group(let g) = items[0] else { return XCTFail("\(items)") }
        XCTAssertEqual(g.callCount, 2)
        XCTAssertEqual(g.finishedCount, 2)
        XCTAssertEqual(g.endedAt, Date(timeIntervalSince1970: base + 4))
        XCTAssertEqual(g.state, .settled)
    }

    // MARK: Outcome

    func testATurnThatIsNotCompleteIsOpen() throws {
        XCTAssertEqual(FoldOutcome.of(try decodeTurn(complete: false, [text("working")])), .open)
    }

    func testACompletedTurnWithACleanResultChipIsCompletedOk() throws {
        let turn = try decodeTurn([text("done"), ["kind": "result_summary", "duration_ms": 5, "cost_usd": 0.1, "is_error": false]])

        XCTAssertEqual(FoldOutcome.of(turn), .completedOk)
    }

    func testACompletedTurnWithAnErrorResultChipIsCompletedError() throws {
        let turn = try decodeTurn([["kind": "result_summary", "duration_ms": 5, "cost_usd": 0.1, "is_error": true]])

        XCTAssertEqual(FoldOutcome.of(turn), .completedError)
    }

    func testACompletedTurnWhoseResultChipSaysInterruptedIsInterruptedNotAnError() throws {
        let turn = try decodeTurn([["kind": "result_summary", "duration_ms": 5, "cost_usd": 0.1, "is_error": true, "interrupted": true]])

        XCTAssertEqual(FoldOutcome.of(turn), .interrupted)
    }

    func testACompletedTurnWithAnErrorMessageBlockIsErrored() throws {
        let turn = try decodeTurn([toolCall(id: "a"), ["kind": "error_message", "message": "connection reset"]])

        XCTAssertEqual(FoldOutcome.of(turn), .errored)
    }

    func testACompletedTurnWithNothingWrongIsCompletedOkEvenWithoutAResultChip() throws {
        XCTAssertEqual(FoldOutcome.of(try decodeTurn([text("hi")])), .completedOk)
    }
}
