import XCTest
@testable import NostromoKit

final class BenchmarkTranscriptTests: XCTestCase {

    private typealias Block = [String: Any]

    private struct Scan {
        var turns: [[String: Any]]
        var blocks: [Block] { turns.flatMap { $0["blocks"] as! [Block] } }
    }

    /// Generating and parsing 1.3 MB is slow in a debug build; the default-seed scans are shared.
    nonisolated(unsafe) private static var cache: [Bool: Scan] = [:]

    private func scan(emptyResults: Bool = false, seed: UInt64 = 1) throws -> Scan {
        if seed == 1, let cached = Self.cache[emptyResults] { return cached }
        let data = BenchmarkTranscript.sessionTurnsJSON(seed: seed, emptyResults: emptyResults)
        let scan = Scan(turns: try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]]))
        if seed == 1 { Self.cache[emptyResults] = scan }
        return scan
    }

    /// Group sizes and prose count derived from the JSON alone, by the PRD's rule.
    private func derive(_ scan: Scan) -> (calls: Int, sizes: [Int], prose: Int) {
        var calls = 0, prose = 0
        var sizes: [Int] = []
        for turn in scan.turns {
            var run = 0
            func close() { if run > 0 { sizes.append(run) }; run = 0 }
            for b in turn["blocks"] as! [Block] {
                switch b["kind"] as! String {
                case "tool_call" where b["parent_tool_use_id"] == nil: calls += 1; run += 1
                case "text" where b["parent_tool_use_id"] == nil:
                    if !(b["text"] as! String).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        prose += 1; close()
                    }
                case "ask_question", "error_message", "result_summary": close()
                default: break
                }
            }
            close()
        }
        return (calls, sizes, prose)
    }

    func testSameSeedIsByteIdentical() {
        XCTAssertEqual(BenchmarkTranscript.sessionTurnsJSON(emptyResults: false),
                       BenchmarkTranscript.sessionTurnsJSON(emptyResults: false))
        XCTAssertNotEqual(BenchmarkTranscript.sessionTurnsJSON(seed: 1, emptyResults: false),
                          BenchmarkTranscript.sessionTurnsJSON(seed: 2, emptyResults: false))
    }

    func testCountsMatchSummary() throws {
        let s = try scan()
        let summary = BenchmarkTranscript.summary
        let d = derive(s)
        XCTAssertGreaterThanOrEqual(s.turns.count, 200)
        XCTAssertGreaterThanOrEqual(d.calls, 5_000)
        XCTAssertEqual(summary.turnCount, s.turns.count)
        XCTAssertEqual(summary.callCount, d.calls)
        XCTAssertEqual(summary.groupCount, d.sizes.count)
        XCTAssertEqual(summary.proseBlockCount, d.prose)
        XCTAssertEqual(summary.groupSizeHistogram, Dictionary(d.sizes.map { ($0, 1) }, uniquingKeysWith: +))
    }

    func testSummaryDoesNotDependOnEmptyResults() throws {
        let d = derive(try scan(emptyResults: true))
        XCTAssertEqual(d.calls, BenchmarkTranscript.summary.callCount)
        XCTAssertEqual(d.sizes.count, BenchmarkTranscript.summary.groupCount)
    }

    func testGroupSizes() throws {
        let h = BenchmarkTranscript.summary.groupSizeHistogram
        for size in [1, 2, 10, 60] { XCTAssertGreaterThanOrEqual(h[size] ?? 0, 3, "groups of \(size)") }
        let others = h.filter { ![1, 2, 10, 60].contains($0.key) }
        XCTAssertTrue(others.keys.allSatisfy { (3 ... 30).contains($0) || $0 == 4 || $0 == 5 })
        XCTAssertGreaterThan(others.count, 10)
    }

    func testToolMix() throws {
        let names = Set(try scan().blocks.compactMap { $0["tool_name"] as? String })
        for n in ["Bash", "Read", "Edit", "Write", "Grep", "Glob", "WebFetch", "Agent", "TodoWrite", "FrobnicateWidget"] {
            XCTAssertTrue(names.contains(n), n)
        }
        XCTAssertTrue(names.contains { $0.hasPrefix("mcp__nostromo__") })
        XCTAssertTrue(names.contains { $0.hasPrefix("mcp__claude_ai_Atlassian__") })
    }

    func testFailuresAboutFourPercentAndOneInAGroupOf60() throws {
        let s = try scan()
        let results = s.blocks.filter { $0["kind"] as? String == "tool_result" }
        let failed = results.filter { $0["is_error"] as? Bool == true }.count
        let ratio = Double(failed) / Double(results.count)
        XCTAssertTrue((0.02 ... 0.07).contains(ratio), "failure ratio \(ratio)")

        var found = false
        for turn in s.turns {
            var run: [Block] = []
            func check() {
                if run.filter({ $0["kind"] as? String == "tool_call" && $0["parent_tool_use_id"] == nil }).count == 60,
                   run.contains(where: { $0["kind"] as? String == "tool_result" && $0["is_error"] as? Bool == true }) {
                    found = true
                }
                run = []
            }
            for b in turn["blocks"] as! [Block] {
                if ["tool_call", "tool_result"].contains(b["kind"] as! String) { run.append(b) } else { check() }
            }
            check()
        }
        XCTAssertTrue(found, "a failed result inside a group of 60")
    }

    func testStuckAndInterruptedTurns() throws {
        let turns = try scan().turns
        func tail(_ turn: [String: Any]) -> (summary: Block, calls: [Block], results: [Block]) {
            let b = turn["blocks"] as! [Block]
            return (b.last!, b.filter { $0["kind"] as? String == "tool_call" },
                    b.filter { $0["kind"] as? String == "tool_result" })
        }
        let stuck = tail(turns[turns.count - 2])
        XCTAssertEqual(stuck.summary["kind"] as? String, "result_summary")
        XCTAssertEqual(stuck.summary["is_error"] as? Bool, true)
        XCTAssertEqual(stuck.summary["interrupted"] as? Bool, false)
        XCTAssertTrue(stuck.results.contains { $0["is_error"] as? Bool == true })

        let interrupted = tail(turns[turns.count - 1])
        XCTAssertEqual(interrupted.summary["is_error"] as? Bool, true)
        XCTAssertEqual(interrupted.summary["interrupted"] as? Bool, true)
        let lastCallId = interrupted.calls.last?["tool_use_id"] as? String
        XCTAssertNotNil(lastCallId)
        XCTAssertFalse(interrupted.results.contains { $0["tool_use_id"] as? String == lastCallId })
        XCTAssertEqual(interrupted.results.count, interrupted.calls.count - 1)
    }

    func testAskCardsAndOneErrorMessageSitBetweenRuns() throws {
        for turn in try scan().turns {
            let b = turn["blocks"] as! [Block]
            for (i, block) in b.enumerated() where ["ask_question", "error_message"].contains(block["kind"] as! String) {
                // A quiet call's result is omitted, so a run may end on its call.
                XCTAssertTrue(["tool_result", "tool_call"].contains(b[i - 1]["kind"] as? String), "preceded by a run")
                XCTAssertEqual(b[i + 1]["kind"] as? String, "tool_call", "followed by a run")
            }
        }
        let blocks = try scan().blocks
        XCTAssertGreaterThanOrEqual(blocks.filter { $0["kind"] as? String == "ask_question" }.count, 3)
        XCTAssertEqual(blocks.filter { $0["kind"] as? String == "error_message" }.count, 1)
    }

    func testEmptyResultsOnlyWhenRequested() throws {
        func empties(_ s: Scan) -> [Block] {
            s.blocks.filter { $0["kind"] as? String == "tool_result"
                && ($0["content"] as? String) == "" && $0["is_error"] as? Bool == false }
        }
        XCTAssertTrue(empties(try scan(emptyResults: false)).isEmpty)
        let with = empties(try scan(emptyResults: true))
        XCTAssertFalse(with.isEmpty)
        // The image-only result is one of them.
        let blocks = try scan(emptyResults: true).blocks
        let png = blocks.first { $0["tool_name"] as? String == "Read" && ($0["target"] as? String)?.hasSuffix(".png") == true }
        let pngId = png?["tool_use_id"] as? String
        XCTAssertTrue(with.contains { $0["tool_use_id"] as? String == pngId })
    }

    func testOne256KBAndOne1MBResult() throws {
        let sizes = try scan().blocks.compactMap { ($0["content"] as? String)?.utf8.count }
        XCTAssertEqual(sizes.filter { $0 == 262_144 }.count, 1)
        XCTAssertEqual(sizes.filter { $0 == 1_048_576 }.count, 1)
        XCTAssertEqual(sizes.max(), 1_048_576)
    }

    func testWhitespaceOnlyProseBetweenTwoCalls() throws {
        var found = false
        for turn in try scan().turns {
            let b = turn["blocks"] as! [Block]
            for (i, block) in b.enumerated() where block["kind"] as? String == "text" {
                let text = block["text"] as! String
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, i > 0, i + 1 < b.count,
                   ["tool_result", "tool_call"].contains(b[i - 1]["kind"] as? String), b[i + 1]["kind"] as? String == "tool_call" {
                    found = true
                }
            }
        }
        XCTAssertTrue(found)
    }

    func testAgentCallCarriesSubagentBlocks() throws {
        var checked = 0
        for turn in try scan().turns {
            let b = turn["blocks"] as! [Block]
            for (i, block) in b.enumerated() where block["tool_name"] as? String == "Agent" {
                let id = block["tool_use_id"] as! String
                let inner = b[(i + 1)...].prefix { $0["parent_tool_use_id"] as? String == id }
                XCTAssertEqual(inner.filter { $0["kind"] as? String == "tool_call" }.count, 3)
                XCTAssertEqual(inner.filter { $0["kind"] as? String == "tool_result" }.count, 3)
                XCTAssertEqual(inner.filter { $0["kind"] as? String == "text" }.count, 1)
                let next = b[i + 1 + inner.count]
                XCTAssertEqual(next["kind"] as? String, "tool_result")
                XCTAssertEqual(next["tool_use_id"] as? String, id)
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 0)
    }

    func testIdsAndTimestamps() throws {
        let s = try scan()
        let ids = s.blocks.filter { $0["kind"] as? String == "tool_call" }.map { $0["tool_use_id"] as! String }
        XCTAssertEqual(Set(ids).count, ids.count, "ids are unique")
        XCTAssertTrue(ids.allSatisfy { $0.hasPrefix("toolu_bench_") })

        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamps = s.blocks.map { f.date(from: $0["ts"] as! String)! }
        XCTAssertEqual(f.string(from: stamps[0]).prefix(4), "2026")
        XCTAssertEqual(stamps, stamps.sorted(), "ts is monotonic in emission order")

        var starts: [String: Date] = [:]
        var durations: [Double] = []
        for b in s.blocks {
            guard let id = b["tool_use_id"] as? String else { continue }
            let at = f.date(from: b["ts"] as! String)!
            if b["kind"] as? String == "tool_call" { starts[id] = at }
            else if let start = starts[id] { durations.append(at.timeIntervalSince(start)) }
        }
        XCTAssertGreaterThanOrEqual(durations.min()!, 0.05 - 0.002)
        XCTAssertLessThanOrEqual(durations.max()!, 200)
        XCTAssertEqual(durations.filter { $0 >= 120 }.count, 1)
    }

    func testTF1KeysOnCallsAndResults() throws {
        for b in try scan().blocks {
            XCTAssertNotNil(b["ts"], "every block has ts")
            if ["tool_call", "tool_result"].contains(b["kind"] as! String) { XCTAssertNotNil(b["tool_use_id"]) }
        }
    }
}
