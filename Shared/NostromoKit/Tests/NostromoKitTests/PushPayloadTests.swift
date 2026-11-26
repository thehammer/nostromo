import XCTest
@testable import NostromoKit

final class PushPayloadTests: XCTestCase {

    func testParsesTheRoutingKeys() {
        let payload = PushPayload.parse(userInfo: [
            "aps": ["alert": ["title": "Mother · kobe", "body": "Job 3f9a1c2e asked a question"], "badge": 2],
            "item": "a1b2c3d4e5f60708", "kind": "mother", "host": "kobe", "ref": "Job 3f9a1c2e",
        ])
        XCTAssertEqual(payload, PushPayload(item: "a1b2c3d4e5f60708", kind: .mother, host: "kobe", ref: "Job 3f9a1c2e"))
        XCTAssertFalse(try XCTUnwrap(payload).resolved)
    }

    func testAReplacementSaysItIsResolved() throws {
        let payload = try XCTUnwrap(PushPayload.parse(userInfo: [
            "item": "a1b2c3d4e5f60708", "kind": "review", "host": "tokyo", "ref": "PR #4821", "resolved": true,
        ]))
        XCTAssertTrue(payload.resolved)
        XCTAssertEqual(payload.kind, .review)
    }

    func testADecisionAndASummaryHaveNoReference() throws {
        let decision = try XCTUnwrap(PushPayload.parse(userInfo: ["item": "x", "kind": "decision", "host": "sendai"]))
        XCTAssertNil(decision.ref)
        let summary = try XCTUnwrap(PushPayload.parse(userInfo: ["item": "summary", "kind": "summary", "host": "all"]))
        XCTAssertEqual(summary.kind, .summary)
    }

    func testUnknownKeysAreIgnored() {
        let payload = PushPayload.parse(userInfo: [
            "item": "x", "kind": "mother", "host": "kobe", "something_new": ["nested": 1], "gcm.message_id": "9",
        ])
        XCTAssertEqual(payload?.item, "x")
    }

    func testAPayloadMissingARequiredKeyOrWithAnUnknownKindIsNotOurs() {
        XCTAssertNil(PushPayload.parse(userInfo: [:]))
        XCTAssertNil(PushPayload.parse(userInfo: ["kind": "mother", "host": "kobe"]))
        XCTAssertNil(PushPayload.parse(userInfo: ["item": "x", "host": "kobe"]))
        XCTAssertNil(PushPayload.parse(userInfo: ["item": "x", "kind": "mother"]))
        XCTAssertNil(PushPayload.parse(userInfo: ["item": "x", "kind": "calendar", "host": "kobe"]))
        XCTAssertNil(PushPayload.parse(userInfo: ["item": "", "kind": "mother", "host": "kobe"]))
        XCTAssertNil(PushPayload.parse(userInfo: ["item": 7, "kind": "mother", "host": "kobe"]))
    }
}
