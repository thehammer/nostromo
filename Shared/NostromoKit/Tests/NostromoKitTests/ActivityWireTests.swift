import XCTest
@testable import NostromoKit

/// `ActivityEvent` / `ActivityStreamWire` are pure decode targets — no logic
/// lives on them. These tests pin the wire contract the daemon side is being
/// built to independently: the two new optional-field cases (minimal,
/// fully-populated), the date strategy, and the three `ServerMsg` cases that
/// carry ambient-activity payloads. A wire-shape regression on either side
/// (Rust or Swift) shows up here first.
///
/// Ported from macOS/NostromoTests/ActivityEventDecodeTests.swift. Neither
/// `ActivityEvent` nor `ActivityStreamWire` has a hand-written initializer —
/// every fixture here is decoded from JSON text via `JSONDecoder.nostromo`,
/// never constructed with named arguments (that's what
/// `ActivityStreamModelTests.swift`'s `makeEvent` factory is for, exercising
/// the compiler-synthesized memberwise init for internal test fixtures; this
/// file is specifically about the `Decodable` conformance and `CodingKeys`
/// snake_case mapping).
final class ActivityWireTests: XCTestCase {

    /// Mirrors the fractional-seconds ISO8601 strategy `NostromodClient`'s
    /// local decoder uses for the same wire messages — `JSONDecoder.nostromo`
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

    func testTsDecodesViaTheFractionalSecondsIso8601StrategyThisPackageAlreadyUses() throws {
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

    // MARK: - ServerMsg.activity

    func testServerMsgDecodesAnActivityFrame() throws {
        let json = """
        {"type":"activity","ts":"2026-01-01T00:00:00Z","agent":"perri","kind":"tool_use","summary":"reading a file","focus_tag":"perri","seq":7}
        """.data(using: .utf8)!

        guard case .activity(let ev) = ServerMsg.decode(from: json) else {
            return XCTFail("expected .activity, got something else")
        }
        XCTAssertEqual(ev.agent, "perri")
        XCTAssertEqual(ev.summary, "reading a file")
        XCTAssertEqual(ev.focusTag, "perri")
        XCTAssertEqual(ev.seq, 7)
    }

    // MARK: - ServerMsg.activitySnapshot

    func testServerMsgDecodesAnActivitySnapshotFrame() throws {
        let json = """
        {
            "type": "activity_snapshot",
            "tag": "perri",
            "streams": [
                {
                    "agent_id": null,
                    "agent_type": null,
                    "parent_agent_id": null,
                    "events": [
                        {"ts":"2026-01-01T00:00:00Z","agent":"perri","kind":"tool_use","summary":"main event"}
                    ],
                    "finished": false
                },
                {
                    "agent_id": "sub-1",
                    "agent_type": "reviewer",
                    "parent_agent_id": "main",
                    "events": [
                        {"ts":"2026-01-01T00:00:01Z","agent":"perri","kind":"subagent_start","summary":"sub event 1","agent_id":"sub-1"},
                        {"ts":"2026-01-01T00:00:02Z","agent":"perri","kind":"subagent_stop","summary":"sub event 2","agent_id":"sub-1"}
                    ],
                    "finished": true
                }
            ]
        }
        """.data(using: .utf8)!

        guard case .activitySnapshot(let tag, let streams) = ServerMsg.decode(from: json) else {
            return XCTFail("expected .activitySnapshot, got something else")
        }
        XCTAssertEqual(tag, "perri")
        XCTAssertEqual(streams.count, 2)

        let main = try XCTUnwrap(streams.first { $0.agentId == nil })
        XCTAssertEqual(main.finished, false)
        XCTAssertEqual(main.events.count, 1)

        let sub = try XCTUnwrap(streams.first { $0.agentId == "sub-1" })
        XCTAssertEqual(sub.finished, true)
        XCTAssertEqual(sub.events.count, 2)
    }

    // MARK: - ServerMsg.activityHealth

    func testServerMsgDecodesAnActivityHealthFrameIncludingLastEventAt() throws {
        let json = """
        {
            "type": "activity_health",
            "ingesting": false,
            "reason": "socket closed",
            "last_event_at": "2026-05-30T09:30:56Z",
            "hook_installed": true
        }
        """.data(using: .utf8)!

        guard case .activityHealth(let ingesting, let reason, let lastEventAt, let hookInstalled)
            = ServerMsg.decode(from: json)
        else {
            return XCTFail("expected .activityHealth, got something else")
        }

        XCTAssertEqual(ingesting, false)
        XCTAssertEqual(reason, "socket closed")
        XCTAssertEqual(hookInstalled, true)

        // last_event_at is real signal in this wedge — iOS's ActivityHealthState
        // retains it even though macOS's AppStore discards it (D2).
        let unwrappedLastEventAt = try XCTUnwrap(lastEventAt, "last_event_at must decode, not be discarded")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let components = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: unwrappedLastEventAt)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 5)
        XCTAssertEqual(components.day, 30)
        XCTAssertEqual(components.hour, 9)
        XCTAssertEqual(components.minute, 30)
        XCTAssertEqual(components.second, 56)
    }
}
