// NostromoKit — TurnOriginTaskWakeWireTests.swift
//
// BA6b: a background task wake's origin (`{"type":"task_wake","items":[…],"omitted":N}`) and the
// `session_turn_origin` frame, decoded against the daemon's goldens in
// `tests/fixtures/background-activity/`.

import XCTest
@testable import NostromoKit

final class TurnOriginTaskWakeWireTests: XCTestCase {

    private static let fixtureDir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // NostromoKitTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // NostromoKit
        .deletingLastPathComponent()   // Shared
        .deletingLastPathComponent()   // <repo>
        .appendingPathComponent("tests/fixtures/background-activity")

    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: Self.fixtureDir.appendingPathComponent(name))
    }

    private func turn(origin: String) throws -> DaemonTurn {
        let json = #"{"id":"t1","user_input":"⟲ fallback","timestamp":null,"blocks":[],"is_complete":true,"origin":\#(origin)}"#
        return try JSONDecoder().decode(DaemonTurn.self, from: Data(json.utf8))
    }

    private let goldenItems = [
        TaskWakeItemWire(taskId: "bmon01", toolUseId: "toolu_01MON", kind: "monitor", outcome: "new_output",
                         description: "CI for PR #251"),
        TaskWakeItemWire(taskId: "bsh02", toolUseId: "toolu_02SH", kind: "shell", outcome: "failed",
                         description: "grep -r 'a<b' && echo \"x\""),
    ]

    func testTheGoldenTurnDecodesTwoItemsFieldForField() throws {
        let decoded = try JSONDecoder().decode(DaemonTurn.self, from: try fixture("turn-task-wake.json"))

        XCTAssertEqual(decoded.origin, .taskWake(items: goldenItems, omitted: 0))
        XCTAssertEqual(decoded.userInput, "⟲ Monitor: new output \"CI for PR #251\"")
    }

    func testTheGoldenFrameDecodesToASessionTurnOrigin() throws {
        let msg = ServerMsg.decode(from: try fixture("session-turn-origin.json"))

        guard case .sessionTurnOrigin(let tag, let turnId, let origin) = msg else { return XCTFail("got \(msg)") }
        XCTAssertEqual(tag, "claudia-ABCD1234")
        XCTAssertEqual(turnId, "t0")
        XCTAssertEqual(origin, .taskWake(items: goldenItems, omitted: 0))
    }

    func testAFrameWhoseOriginDoesNotDecodeIsUnknown() {
        for origin in [#"{"type":"future_thing","items":[]}"#, #"{"type":"task_wake","items":[]}"#,
                       #"{"type":"task_wake","items":[1,"x"]}"#] {
            let json = #"{"type":"session_turn_origin","tag":"t","turn_id":"t0","origin":\#(origin)}"#
            guard case .unknown = ServerMsg.decode(from: Data(json.utf8)) else { return XCTFail(origin) }
        }
    }

    func testOmittedIsReadAndDefaultsToZero() throws {
        XCTAssertEqual(try turn(origin: #"{"type":"task_wake","items":[{"kind":"shell"}],"omitted":7}"#).origin?.taskWakeOmitted, 7)
        XCTAssertEqual(try turn(origin: #"{"type":"task_wake","items":[{"kind":"shell"}]}"#).origin?.taskWakeOmitted, 0)
    }

    func testMissingFieldsTakeTheirDefaults() throws {
        let origin = try turn(origin: #"{"type":"task_wake","items":[{}]}"#).origin

        XCTAssertEqual(origin, .taskWake(items: [TaskWakeItemWire(kind: "other", outcome: "event", description: "")], omitted: 0))
    }

    func testAnUnknownKindAndOutcomeAreKeptAsText() throws {
        let origin = try turn(origin: #"{"type":"task_wake","items":[{"task_id":"a","kind":"cron","outcome":"paused","description":"d"}]}"#).origin

        XCTAssertEqual(origin?.taskWakeItems.first?.kind, "cron")
        XCTAssertEqual(origin?.taskWakeItems.first?.outcome, "paused")
    }

    func testMalformedItemsAreSkippedAndNoneLeftMeansNoOrigin() throws {
        let some = try turn(origin: #"{"type":"task_wake","items":[7,{"task_id":"a","kind":"shell","outcome":"failed","description":"d"}]}"#).origin
        XCTAssertEqual(some?.taskWakeItems.count, 1)

        let none = try turn(origin: #"{"type":"task_wake","items":[7,"x",null]}"#)
        XCTAssertNil(none.origin)
        XCTAssertEqual(none.userInput, "⟲ fallback")
    }

    func testAnUnknownOriginTypeIsStillNil() throws {
        XCTAssertNil(try turn(origin: #"{"type":"never_heard_of_it","items":[]}"#).origin)
    }

    func testRoundTripAndTheOtherOriginsAreUnchanged() throws {
        let origin = TurnOriginWire.taskWake(items: goldenItems, omitted: 3)
        let again = try JSONDecoder().decode(TurnOriginWire.self, from: JSONEncoder().encode(origin))
        XCTAssertEqual(again, origin)
        XCTAssertEqual(origin.items, [])
        XCTAssertEqual(origin.motherNoticeItems, [])

        let mother = try turn(origin: #"{"type":"mother_job_notice","items":[{"job_id":"j","title":"t","state":"failed"}]}"#).origin
        XCTAssertEqual(mother?.motherNoticeItems.count, 1)
        XCTAssertEqual(mother?.taskWakeItems, [])
    }
}
