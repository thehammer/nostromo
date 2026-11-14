// NostromoKit — TurnOriginLocalCommandWireTests.swift
//
// A slash command the CLI answered itself, as the shared Kit decodes it:
//   {"type":"local_command","command":"context","args":"","output":"…","stream":"stdout","truncated":false}
//
// Optional fields default (args "", output "", stream "stdout", truncated false). A missing `command`
// makes the origin meaningless, so decoding it throws and a turn carrying it falls back to a nil
// origin (the plain bubble of its `user_input`). An unknown origin type still throws.

import XCTest
@testable import NostromoKit

final class TurnOriginLocalCommandWireTests: XCTestCase {

    // MARK: - Helpers

    private func origin(_ json: String) throws -> TurnOriginWire {
        try JSONDecoder().decode(TurnOriginWire.self, from: Data(json.utf8))
    }

    private func turn(origin: String) throws -> DaemonTurn {
        let json = #"{"id":"t1","user_input":"/context","timestamp":null,"blocks":[],"is_complete":true,"origin":\#(origin)}"#
        return try JSONDecoder().decode(DaemonTurn.self, from: Data(json.utf8))
    }

    // MARK: - Decoding

    func testAFullLocalCommandDecodesFieldForField() throws {
        let decoded = try origin(#"""
        {"type":"local_command","command":"model","args":"haiku","output":"Set model to Haiku",
         "stream":"stderr","truncated":true}
        """#)

        XCTAssertEqual(decoded, .localCommand(command: "model", args: "haiku", output: "Set model to Haiku",
                                              stream: "stderr", truncated: true))
    }

    func testMissingOptionalFieldsTakeTheirDefaults() throws {
        let decoded = try origin(#"{"type":"local_command","command":"context"}"#)

        XCTAssertEqual(decoded, .localCommand(command: "context", args: "", output: "",
                                              stream: "stdout", truncated: false))
    }

    func testNullAndMistypedOptionalFieldsFallBackToTheirDefaultsInsteadOfFailing() throws {
        let decoded = try origin(#"""
        {"type":"local_command","command":"context","args":null,"output":7,"stream":["x"],"truncated":"yes"}
        """#)

        XCTAssertEqual(decoded, .localCommand(command: "context", args: "", output: "",
                                              stream: "stdout", truncated: false))
    }

    func testUnknownFieldsAreIgnored() throws {
        let decoded = try origin(#"{"type":"local_command","command":"usage","output":"x","exit_code":0,"future":{"a":1}}"#)

        XCTAssertEqual(decoded, .localCommand(command: "usage", args: "", output: "x",
                                              stream: "stdout", truncated: false))
    }

    func testAMissingCommandThrows() {
        XCTAssertThrowsError(try origin(#"{"type":"local_command","args":"x","output":"y"}"#))
    }

    func testAMistypedCommandThrows() {
        XCTAssertThrowsError(try origin(#"{"type":"local_command","command":5}"#))
    }

    func testAnUnknownOriginTypeStillThrows() {
        XCTAssertThrowsError(try origin(#"{"type":"local_command_v2","command":"context"}"#))
        XCTAssertThrowsError(try origin(#"{"type":"future_thing"}"#))
    }

    func testOutputWithControlCharactersAndHugeTextDecodesVerbatim() throws {
        let hostile = "line1\n\u{1B}[31mred\u{202E}evil\u{0}x"
        let huge = String(repeating: "W", count: 100_000)
        let object: [String: Any] = ["type": "local_command", "command": "context", "output": hostile + huge]
        let json = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(TurnOriginWire.self, from: json)

        guard case .localCommand(_, _, let output, _, _) = decoded else { return XCTFail("\(decoded)") }
        XCTAssertEqual(output, hostile + huge)
    }

    // MARK: - A turn carrying it

    func testATurnWithALocalCommandOriginCarriesIt() throws {
        let decoded = try turn(origin: #"{"type":"local_command","command":"context","output":"3k tokens"}"#)

        XCTAssertEqual(decoded.userInput, "/context")
        XCTAssertEqual(decoded.origin, .localCommand(command: "context", args: "", output: "3k tokens",
                                                     stream: "stdout", truncated: false))
    }

    func testATurnWhoseLocalCommandHasNoCommandFallsBackToANilOrigin() throws {
        let decoded = try turn(origin: #"{"type":"local_command","output":"orphan"}"#)

        XCTAssertNil(decoded.origin, "the turn must survive as an ordinary bubble of its user_input")
        XCTAssertEqual(decoded.userInput, "/context")
    }

    func testALocalCommandOriginHasNoTerminalItems() {
        XCTAssertEqual(TurnOriginWire.localCommand(command: "c", args: "", output: "", stream: "stdout",
                                                   truncated: false).items.count, 0)
    }

    // MARK: - Encoding

    func testEncodingRoundTripsEveryField() throws {
        for original in [
            TurnOriginWire.localCommand(command: "model", args: "haiku", output: "ok", stream: "stderr", truncated: true),
            TurnOriginWire.localCommand(command: "context", args: "", output: "", stream: "stdout", truncated: false),
        ] {
            let data = try JSONEncoder().encode(original)
            XCTAssertEqual(try JSONDecoder().decode(TurnOriginWire.self, from: data), original)
        }
    }

    func testEncodingEmitsTruncatedOnlyWhenTrue() throws {
        func keys(_ o: TurnOriginWire) throws -> [String: Any] {
            let data = try JSONEncoder().encode(o)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        let plain = try keys(.localCommand(command: "c", args: "a", output: "o", stream: "stdout", truncated: false))
        XCTAssertNil(plain["truncated"])
        XCTAssertEqual(plain["type"] as? String, "local_command")
        XCTAssertEqual(plain["command"] as? String, "c")
        XCTAssertEqual(plain["args"] as? String, "a")
        XCTAssertEqual(plain["output"] as? String, "o")
        XCTAssertEqual(plain["stream"] as? String, "stdout")

        let cut = try keys(.localCommand(command: "c", args: "a", output: "o", stream: "stdout", truncated: true))
        XCTAssertEqual(cut["truncated"] as? Bool, true)
    }
}
