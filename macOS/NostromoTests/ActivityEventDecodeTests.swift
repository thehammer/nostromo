import XCTest
import NostromoKit

/// `ActivityEvent` is a pure decode target: no logic lives on it. These tests
/// pin the wire contract the daemon side is being built to independently —
/// the two new optional-field cases (minimal, fully-populated) and the date
/// strategy — so a wire-shape regression on either side shows up here first.
///
/// `ActivityEvent` itself is compiled into this target via `Models.swift`'s
/// dual (app + test) membership, same as `Theme.swift`/`ChatModels.swift`.
final class ActivityEventDecodeTests: XCTestCase {

    /// Mirrors the fractional-seconds ISO8601 strategy `NostromodClient`'s
    /// local decoder uses for the same wire messages (see
    /// `NostromodClient.swift`'s `decoder` property) — `JSONDecoder.nostromo`
    /// is the NostromoKit-published version of that exact strategy.
    private let decoder = JSONDecoder.nostromo

    // MARK: - Minimal payload

    func testMinimalFourFieldPayloadDecodesWithAllNewFieldsNil() throws {
        let json = """
        {"ts":"2026-01-01T00:00:00Z","agent":"perri","kind":"tool_use","summary":"reading a file"}
        """.data(using: .utf8)!

        let ev = try decoder.decode(ActivityEvent.self, from: json)

        XCTAssertEqual(ev.agent, "perri")
        XCTAssertEqual(ev.kind, "tool_use")
        XCTAssertEqual(ev.summary, "reading a file")
        XCTAssertNil(ev.focusTag)
        XCTAssertNil(ev.sessionId)
        XCTAssertNil(ev.agentId)
        XCTAssertNil(ev.agentType)
        XCTAssertNil(ev.parentAgentId)
        XCTAssertNil(ev.toolName)
        XCTAssertNil(ev.toolUseId)
        XCTAssertNil(ev.cwd)
        XCTAssertNil(ev.seq)
    }

    // MARK: - Fully-populated payload

    func testFullyPopulatedPayloadDecodesEveryNewField() throws {
        let json = """
        {
            "ts": "2026-01-01T00:00:00.123456Z",
            "agent": "perri",
            "kind": "subagent_start",
            "summary": "reviewing PR #42",
            "focus_tag": "perri",
            "session_id": "sess-abc123",
            "agent_id": "sub-1",
            "agent_type": "reviewer",
            "parent_agent_id": "main",
            "tool_name": "Bash",
            "tool_use_id": "tool-xyz",
            "cwd": "/Users/hammer/Code/nostromo",
            "seq": 42
        }
        """.data(using: .utf8)!

        let ev = try decoder.decode(ActivityEvent.self, from: json)

        XCTAssertEqual(ev.agent, "perri")
        XCTAssertEqual(ev.kind, "subagent_start")
        XCTAssertEqual(ev.summary, "reviewing PR #42")
        XCTAssertEqual(ev.focusTag, "perri")
        XCTAssertEqual(ev.sessionId, "sess-abc123")
        XCTAssertEqual(ev.agentId, "sub-1")
        XCTAssertEqual(ev.agentType, "reviewer")
        XCTAssertEqual(ev.parentAgentId, "main")
        XCTAssertEqual(ev.toolName, "Bash")
        XCTAssertEqual(ev.toolUseId, "tool-xyz")
        XCTAssertEqual(ev.cwd, "/Users/hammer/Code/nostromo")
        XCTAssertEqual(ev.seq, 42)
    }

    // MARK: - Date strategy

    func testTsDecodesViaTheFractionalSecondsIso8601StrategyThisTargetAlreadyUses() throws {
        // Plain (non-fractional) ISO8601 — the "basic" leg of the strategy.
        let basic = """
        {"ts":"2026-05-30T09:30:56Z","agent":"perri","kind":"tool_use","summary":"x"}
        """.data(using: .utf8)!
        let evBasic = try decoder.decode(ActivityEvent.self, from: basic)

        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let basicComponents = cal.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: evBasic.ts)
        XCTAssertEqual(basicComponents.year, 2026)
        XCTAssertEqual(basicComponents.month, 5)
        XCTAssertEqual(basicComponents.day, 30)
        XCTAssertEqual(basicComponents.hour, 9)
        XCTAssertEqual(basicComponents.minute, 30)
        XCTAssertEqual(basicComponents.second, 56)

        // Fractional-seconds ISO8601 — the leg Swift's built-in .iso8601 strategy
        // rejects, and the reason this codebase has a custom strategy at all.
        let fractional = """
        {"ts":"2026-05-30T09:30:56.510874Z","agent":"perri","kind":"tool_use","summary":"x"}
        """.data(using: .utf8)!
        let evFractional = try decoder.decode(ActivityEvent.self, from: fractional)
        XCTAssertEqual(
            evFractional.ts.timeIntervalSince(evBasic.ts), 0.510874, accuracy: 0.001,
            "fractional seconds must not be truncated or rejected")
    }
}
