import XCTest
import NostromoKit

// DaemonTurn is compiled into this test target directly (logic test — no host app).
// `ChatSession.mapTurn` is private, so this goes through the same
// `JSONDecoder` -> `DaemonTurn` path the daemon's `sessionTurns` snapshot takes.

/// The benchmark generator's JSON must decode through the Mac's real wire
/// decoder, or the load harness's fixture mode measures nothing.
final class BenchmarkTranscriptMacTests: XCTestCase {

    func testGeneratorJSONDecodesThroughDaemonTurn() throws {
        let data = BenchmarkTranscript.sessionTurnsJSON(emptyResults: false)
        let turns = try JSONDecoder().decode([DaemonTurn].self, from: data)
        let summary = BenchmarkTranscript.summary

        XCTAssertEqual(turns.count, summary.turnCount)
        XCTAssertGreaterThanOrEqual(turns.count, 200)

        var calls = 0
        for turn in turns {
            for block in turn.blocks {
                if case .toolCall = block { calls += 1 }
            }
        }
        // `DaemonTurnBlock` doesn't decode `parent_tool_use_id` yet (TF1), so the
        // count includes the subagent calls on top of the top-level ones.
        XCTAssertGreaterThanOrEqual(calls, summary.callCount)
        XCTAssertGreaterThanOrEqual(summary.callCount, 5_000)
    }
}
