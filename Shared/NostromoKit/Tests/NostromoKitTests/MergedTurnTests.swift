// NostromoKit — MergedTurnTests.swift
//
// Merged turns (S3, `merged_turns_v1`): a turn that answers several queued messages the daemon
// wrote as one frame carries `user_parts`. The golden JSON is copied from
// `tests/fixtures/merged_turns/` (the Rust tests pin the same bytes).

import XCTest
import Combine
@testable import NostromoKit

@MainActor
final class MergedTurnTests: XCTestCase {

    static let mergedStarted = #"""
    {"type":"session_turn_delta","tag":"cody-1","delta":{"delta":"turn_started","turn":{"id":"t1","user_input":"oh and backfill the rows\n\nuse the new column name","timestamp":null,"blocks":[],"is_complete":false,"user_parts":["oh and backfill the rows","use the new column name"]}}}
    """#

    static let oldStarted = #"""
    {"type":"session_turn_delta","tag":"cody-1","delta":{"delta":"turn_started","turn":{"id":"t1","user_input":"hello","timestamp":null,"blocks":[],"is_complete":false}}}
    """#

    private func turn(of json: String) throws -> DaemonTurn {
        let msg = ServerMsg.decode(from: Data(json.utf8))
        guard case .sessionTurnDelta(_, .turnStarted(let turn)) = msg else {
            XCTFail("not a turn_started: \(msg)"); throw CocoaError(.coderInvalidValue)
        }
        return turn
    }

    // MARK: decode

    func testATurnWithUserPartsDecodesThem() throws {
        let t = try turn(of: Self.mergedStarted)
        XCTAssertEqual(t.userParts, ["oh and backfill the rows", "use the new column name"])
        XCTAssertEqual(t.userInput, "oh and backfill the rows\n\nuse the new column name")
    }

    func testATurnWithoutUserPartsDecodesWithNone() throws {
        let t = try turn(of: Self.oldStarted)
        XCTAssertEqual(t.userParts, [])
        XCTAssertEqual(t.userInput, "hello")
    }

    func testAClientThatIgnoresUserPartsShowsOneBubbleOfTheJoinedText() throws {
        // The same frame with the field dropped, as an older client would see it.
        var json = try JSONSerialization.jsonObject(with: Data(Self.mergedStarted.utf8)) as! [String: Any]
        var delta = json["delta"] as! [String: Any]
        var turn = delta["turn"] as! [String: Any]
        turn.removeValue(forKey: "user_parts")
        delta["turn"] = turn
        json["delta"] = delta
        let data = try JSONSerialization.data(withJSONObject: json)
        let msg = ServerMsg.decode(from: data)
        guard case .sessionTurnDelta(_, .turnStarted(let t)) = msg else { return XCTFail() }
        XCTAssertTrue(t.userParts.isEmpty)
        XCTAssertEqual(t.userInput, "oh and backfill the rows\n\nuse the new column name")
        XCTAssertFalse(t.userInput.contains("nostromo-batch"), "no framing")
    }

    // MARK: hello

    func testHelloCarriesTheMergedTurnsCapability() throws {
        let data = try JSONEncoder().encode(ClientHello(clientId: "c", protocolVersion: 4))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(json["capabilities"] as? [String], ["merged_turns_v1"])
        XCTAssertEqual(json["type"] as? String, "hello")
    }

    // MARK: echoes

    private func storeWithEchoes(_ texts: [String]) -> (TranscriptStore, NetworkClient) {
        let client = NetworkClient()
        let store = TranscriptStore(client: client)
        store.attach(tag: "cody-1", agentName: "cody", viewName: "View")
        texts.forEach { store.send($0) }
        return (store, client)
    }

    private func deliver(_ json: String, via client: NetworkClient, in store: TranscriptStore,
                         until done: @escaping ([DaemonTurn]) -> Bool) throws {
        let msg = ServerMsg.decode(from: Data(json.utf8))
        let ready = expectation(description: "the store applied the turn")
        var bag = Set<AnyCancellable>()
        store.$turns.sink { if done($0) { ready.fulfill() } }.store(in: &bag)
        client.messages.send(msg)
        wait(for: [ready], timeout: 5)
    }

    func testAMergedTurnRemovesTheEchoOfEachOfItsParts() throws {
        let (store, client) = storeWithEchoes(["oh and backfill the rows", "use the new column name", "unrelated"])
        XCTAssertEqual(store.turns.count, 3)

        try deliver(Self.mergedStarted, via: client, in: store) { $0.contains { $0.id == "t1" } }

        XCTAssertEqual(store.turns.map(\.id).filter { $0.hasPrefix("local-") }.count, 1)
        XCTAssertEqual(store.turns.filter { $0.id.hasPrefix("local-") }.map(\.userInput), ["unrelated"])
        XCTAssertEqual(store.turns.last?.userParts.count, 2)
    }

    func testAPlainTurnRemovesItsEchoAndOnlyOne() throws {
        let (store, client) = storeWithEchoes(["hello", "hello"])
        XCTAssertEqual(store.turns.count, 2)

        try deliver(Self.oldStarted, via: client, in: store) { $0.contains { $0.id == "t1" } }

        XCTAssertEqual(store.turns.filter { $0.id.hasPrefix("local-") }.count, 1,
                       "at most one echo per message")
        XCTAssertEqual(store.turns.filter { $0.id == "t1" }.count, 1)
    }
}
