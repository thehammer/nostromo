// NostromoKit — TurnOriginPeerWireTests.swift
//
// A user-role message the CLI injected, as the shared Kit decodes it:
//   {"type":"peer_message","items":[{from_name?,from_mode?,from_socket?,body,truncated}],"omitted":N}
//   {"type":"injected_context","kind":"skill|summary|other","title":…,"text":…,"truncated":bool}
//
// Decoding is tolerant of everything but the two things that make an origin meaningless: an unknown
// `type`, and a `peer_message` with no readable item (like a task wake with none). Absent, null and
// mistyped fields fall back to defaults; unknown fields are ignored; an item that is not an object is
// skipped and the others survive.

import XCTest
@testable import NostromoKit

final class TurnOriginPeerWireTests: XCTestCase {

    // MARK: - Helpers

    private func origin(_ json: String) throws -> TurnOriginWire {
        try JSONDecoder().decode(TurnOriginWire.self, from: Data(json.utf8))
    }

    private func peerOrigin(items: String, extra: String = "") throws -> TurnOriginWire {
        try origin(#"{"type":"peer_message","items":\#(items)\#(extra)}"#)
    }

    private func turn(origin: String) throws -> DaemonTurn {
        let json = #"{"id":"t1","user_input":"raw tag text","timestamp":null,"blocks":[],"is_complete":true,"origin":\#(origin)}"#
        return try JSONDecoder().decode(DaemonTurn.self, from: Data(json.utf8))
    }

    private func peerItems(_ origin: TurnOriginWire, file: StaticString = #filePath, line: UInt = #line) -> [PeerMessageItemWire] {
        guard case .peerMessage(let items, _) = origin else {
            XCTFail("not a peer_message: \(origin)", file: file, line: line)
            return []
        }
        return items
    }

    private let full = PeerMessageItemWire(fromName: "PDO Demo", fromMode: "bypass", fromSocket: "/tmp/pdo.sock",
                                           body: "run the tests", truncated: true)

    // MARK: - peer_message: present values

    func testAFullPeerMessageDecodesFieldForField() throws {
        let decoded = try origin(#"""
        {"type":"peer_message","omitted":2,
         "items":[{"from_name":"PDO Demo","from_mode":"bypass","from_socket":"/tmp/pdo.sock","body":"run the tests","truncated":true}]}
        """#)

        XCTAssertEqual(decoded, .peerMessage(items: [full], omitted: 2))
    }

    func testSeveralItemsKeepTheirOrder() throws {
        let decoded = try peerOrigin(items: #"[{"body":"one"},{"body":"two"},{"body":"three"}]"#)

        XCTAssertEqual(peerItems(decoded).map(\.body), ["one", "two", "three"])
    }

    func testAnOldWireItemWithOnlyABodyHasNoSenderAndIsNotTruncated() throws {
        let decoded = try peerOrigin(items: #"[{"body":"hi"}]"#)

        XCTAssertEqual(decoded, .peerMessage(items: [PeerMessageItemWire(body: "hi")], omitted: 0))
        XCTAssertNil(peerItems(decoded).first?.fromName)
        XCTAssertNil(peerItems(decoded).first?.fromMode)
        XCTAssertNil(peerItems(decoded).first?.fromSocket)
        XCTAssertEqual(peerItems(decoded).first?.truncated, false)
    }

    func testUnknownFieldsOnTheOriginAndTheItemAreIgnored() throws {
        let decoded = try origin(#"""
        {"type":"peer_message","future_field":{"a":1},
         "items":[{"from_name":"A","body":"b","from_pid":4242,"nested":[1,2,3]}]}
        """#)

        XCTAssertEqual(decoded, .peerMessage(items: [PeerMessageItemWire(fromName: "A", body: "b")], omitted: 0))
    }

    // MARK: - peer_message: absent and hostile values

    func testAnItemWithNoFieldsAtAllIsAnEmptyMessage() throws {
        let decoded = try peerOrigin(items: "[{}]")

        XCTAssertEqual(decoded, .peerMessage(items: [PeerMessageItemWire(body: "")], omitted: 0))
    }

    func testNullFieldsAreAbsentFields() throws {
        let decoded = try peerOrigin(items: #"[{"from_name":null,"from_mode":null,"from_socket":null,"body":null,"truncated":null}]"#)

        XCTAssertEqual(decoded, .peerMessage(items: [PeerMessageItemWire(body: "")], omitted: 0))
    }

    func testMistypedFieldsFallBackToTheirDefaultsInsteadOfDroppingTheItem() throws {
        let decoded = try peerOrigin(items: #"[{"from_name":5,"from_mode":["x"],"from_socket":{},"body":7,"truncated":"yes"}]"#)

        XCTAssertEqual(decoded, .peerMessage(items: [PeerMessageItemWire(body: "")], omitted: 0))
    }

    func testOneMistypedFieldDoesNotCostTheItemsOtherFields() throws {
        let decoded = try peerOrigin(items: #"[{"from_name":"A","from_mode":9,"body":"keep me"}]"#)

        XCTAssertEqual(decoded, .peerMessage(items: [PeerMessageItemWire(fromName: "A", body: "keep me")], omitted: 0))
    }

    func testControlAndBidiCharactersAndHugeTextDecodeVerbatimForTheMarkerTextToSanitise() throws {
        let hostile = "\u{1B}[31mred\u{202E}evil\u{0}x"
        let huge = String(repeating: "W", count: 100_000)
        let object: [String: Any] = ["type": "peer_message", "items": [["from_name": hostile, "body": huge]]]
        let json = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(TurnOriginWire.self, from: json)

        XCTAssertEqual(peerItems(decoded).first?.fromName, hostile)
        XCTAssertEqual(peerItems(decoded).first?.body.count, 100_000)
    }

    func testOmittedIsReadAndDefaultsToZero() throws {
        XCTAssertEqual(try peerOrigin(items: #"[{"body":"x"}]"#, extra: #","omitted":7"#),
                       .peerMessage(items: [PeerMessageItemWire(body: "x")], omitted: 7))
        XCTAssertEqual(try peerOrigin(items: #"[{"body":"x"}]"#),
                       .peerMessage(items: [PeerMessageItemWire(body: "x")], omitted: 0))
    }

    func testANegativeOrMistypedOmittedCountsAsZero() throws {
        for extra in [#","omitted":-4"#, #","omitted":"many""#, #","omitted":null"#, #","omitted":1.5"#] {
            XCTAssertEqual(try peerOrigin(items: #"[{"body":"x"}]"#, extra: extra),
                           .peerMessage(items: [PeerMessageItemWire(body: "x")], omitted: 0), extra)
        }
    }

    // MARK: - peer_message: unreadable items

    func testAnItemThatIsNotAnObjectIsSkippedAndTheOthersSurvive() throws {
        let decoded = try peerOrigin(items: #"[7,{"from_name":"A","body":"ok"},"x",null,[1],{"body":"also ok"}]"#)

        XCTAssertEqual(peerItems(decoded), [PeerMessageItemWire(fromName: "A", body: "ok"), PeerMessageItemWire(body: "also ok")])
    }

    func testAPeerMessageWithNoReadableItemIsNotAnOrigin() {
        for items in ["[]", #"[7,"x",null]"#, #"[[],[1]]"#] {
            XCTAssertThrowsError(try peerOrigin(items: items), "items \(items)")
        }
    }

    func testAPeerMessageWhoseItemsAreAbsentOrNotAnArrayIsNotAnOrigin() {
        for json in [#"{"type":"peer_message"}"#, #"{"type":"peer_message","items":null}"#,
                     #"{"type":"peer_message","items":"x"}"#, #"{"type":"peer_message","items":{"body":"x"}}"#] {
            XCTAssertThrowsError(try origin(json), json)
        }
    }

    func testATurnWhosePeerOriginHasNoReadableItemDecodesWithNoOriginAndKeepsItsText() throws {
        let decoded = try turn(origin: #"{"type":"peer_message","items":[7,"x"]}"#)

        XCTAssertNil(decoded.origin, "the transcript shows the plain bubble it would otherwise hide")
        XCTAssertEqual(decoded.userInput, "raw tag text")
    }

    func testAFrameWhoseOriginDoesNotDecodeIsUnknown() {
        for origin in [#"{"type":"peer_message","items":[]}"#, #"{"type":"peer_message","items":[1]}"#,
                       #"{"type":"peer_messages","items":[{"body":"x"}]}"#] {
            let json = #"{"type":"session_turn_origin","tag":"t","turn_id":"t0","origin":\#(origin)}"#
            guard case .unknown = ServerMsg.decode(from: Data(json.utf8)) else { return XCTFail(origin) }
        }
    }

    // MARK: - injected_context

    func testAFullInjectedContextDecodesFieldForField() throws {
        let decoded = try origin(#"{"type":"injected_context","kind":"skill","title":"my-skill","text":"Body text","truncated":true}"#)

        XCTAssertEqual(decoded, .injectedContext(kind: "skill", title: "my-skill", text: "Body text", truncated: true))
    }

    func testAnInjectedContextWithNoFieldsIsOtherContextWithNoTextAndNotTruncated() throws {
        let decoded = try origin(#"{"type":"injected_context"}"#)

        XCTAssertEqual(decoded, .injectedContext(kind: "other", title: "", text: "", truncated: false))
    }

    func testNullAndMistypedInjectedFieldsFallBackToTheirDefaults() throws {
        for json in [#"{"type":"injected_context","kind":null,"title":null,"text":null,"truncated":null}"#,
                     #"{"type":"injected_context","kind":5,"title":["t"],"text":{},"truncated":"yes"}"#] {
            XCTAssertEqual(try origin(json), .injectedContext(kind: "other", title: "", text: "", truncated: false), json)
        }
    }

    func testAnUnknownKindIsKeptAsText() throws {
        let decoded = try origin(#"{"type":"injected_context","kind":"from_the_future","text":"x"}"#)

        XCTAssertEqual(decoded, .injectedContext(kind: "from_the_future", title: "", text: "x", truncated: false))
    }

    func testUnknownFieldsOnAnInjectedContextAreIgnored() throws {
        let decoded = try origin(#"{"type":"injected_context","kind":"summary","text":"s","bytes":12,"extra":{"a":1}}"#)

        XCTAssertEqual(decoded, .injectedContext(kind: "summary", title: "", text: "s", truncated: false))
    }

    func testATurnCarriesAnInjectedContextOrigin() throws {
        let decoded = try turn(origin: #"{"type":"injected_context","kind":"skill","title":"t","text":"x"}"#)

        XCTAssertEqual(decoded.origin, .injectedContext(kind: "skill", title: "t", text: "x", truncated: false))
        XCTAssertEqual(decoded.userInput, "raw tag text")
    }

    // MARK: - Unknown types and frames

    func testAnUnknownOriginTypeStillThrowsAndATurnWithOneHasNoOrigin() throws {
        for json in [#"{"type":"never_heard_of_it","items":[{"body":"x"}]}"#, #"{"type":"Peer_Message","items":[{"body":"x"}]}"#,
                     #"{"type":"INJECTED_CONTEXT"}"#, #"{"items":[{"body":"x"}]}"#] {
            XCTAssertThrowsError(try origin(json), json)
            XCTAssertNil(try turn(origin: json).origin, json)
        }
    }

    func testTheSessionTurnOriginFrameCarriesBothNewOrigins() throws {
        let cases: [(String, TurnOriginWire)] = [
            (#"{"type":"peer_message","items":[{"from_name":"A","body":"b"}],"omitted":1}"#,
             .peerMessage(items: [PeerMessageItemWire(fromName: "A", body: "b")], omitted: 1)),
            (#"{"type":"injected_context","kind":"summary","text":"s"}"#,
             .injectedContext(kind: "summary", title: "", text: "s", truncated: false)),
        ]
        for (json, expected) in cases {
            let frame = #"{"type":"session_turn_origin","tag":"claudia-1","turn_id":"t3","origin":\#(json)}"#

            guard case .sessionTurnOrigin(let tag, let turnId, let decoded) = ServerMsg.decode(from: Data(frame.utf8)) else {
                return XCTFail(json)
            }
            XCTAssertEqual(tag, "claudia-1")
            XCTAssertEqual(turnId, "t3")
            XCTAssertEqual(decoded, expected)
        }
    }

    // MARK: - Round trip

    func testPeerMessagesRoundTripWithAndWithoutOmittedAndOptionalFields() throws {
        let origins: [TurnOriginWire] = [
            .peerMessage(items: [full, PeerMessageItemWire(body: "bare")], omitted: 3),
            .peerMessage(items: [PeerMessageItemWire(fromName: "A", body: "x")], omitted: 0),
        ]
        for origin in origins {
            let again = try JSONDecoder().decode(TurnOriginWire.self, from: JSONEncoder().encode(origin))

            XCTAssertEqual(again, origin)
        }
    }

    func testInjectedContextsRoundTripTruncatedOrNot() throws {
        for truncated in [true, false] {
            let origin = TurnOriginWire.injectedContext(kind: "skill", title: "my-skill", text: "line one\nline two", truncated: truncated)

            let again = try JSONDecoder().decode(TurnOriginWire.self, from: JSONEncoder().encode(origin))

            XCTAssertEqual(again, origin)
        }
    }

    func testTheEncodedFormIsTheWireTheDaemonSends() throws {
        let peer = try JSONSerialization.jsonObject(with: JSONEncoder().encode(TurnOriginWire.peerMessage(items: [full], omitted: 0))) as? [String: Any]
        XCTAssertEqual(peer?["type"] as? String, "peer_message")
        let item = (peer?["items"] as? [[String: Any]])?.first
        XCTAssertEqual(item?["from_name"] as? String, "PDO Demo")
        XCTAssertEqual(item?["from_mode"] as? String, "bypass")
        XCTAssertEqual(item?["body"] as? String, "run the tests")

        let injected = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(TurnOriginWire.injectedContext(kind: "skill", title: "t", text: "x", truncated: false))) as? [String: Any]
        XCTAssertEqual(injected?["type"] as? String, "injected_context")
        XCTAssertEqual(injected?["kind"] as? String, "skill")
    }

    func testTheNewOriginsHoldNoTerminalMotherOrWakeItems() {
        for origin in [TurnOriginWire.peerMessage(items: [full], omitted: 4), .injectedContext(kind: "skill", title: "t", text: "x", truncated: false)] {
            XCTAssertEqual(origin.items, [])
            XCTAssertEqual(origin.motherNoticeItems, [])
            XCTAssertEqual(origin.taskWakeItems, [])
            XCTAssertEqual(origin.taskWakeOmitted, 0)
        }
    }
}
