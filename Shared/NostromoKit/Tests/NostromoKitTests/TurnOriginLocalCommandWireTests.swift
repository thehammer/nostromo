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

        guard case .localCommand(_, _, let output, _, _, _) = decoded else { return XCTFail("\(decoded)") }
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

    // MARK: - Compact detail (`/compact` record)

    private func compact(_ json: String) throws -> CompactInfoWire? {
        let decoded = try origin(json)
        guard case .localCommand(_, _, _, _, _, let info) = decoded else { XCTFail("\(decoded)"); return nil }
        return info
    }

    func testASuccessfulCompactDecodesItsTokenCounts() throws {
        let info = try compact(#"""
        {"type":"local_command","command":"compact","output":"Compacted",
         "compact":{"pre_tokens":45123,"post_tokens":19700}}
        """#)

        XCTAssertEqual(info, CompactInfoWire(preTokens: 45123, postTokens: 19700, failed: false, error: nil))
    }

    func testAFailedCompactDecodesItsReason() throws {
        let info = try compact(#"""
        {"type":"local_command","command":"compact","stream":"stderr",
         "compact":{"failed":true,"error":"Not enough messages to compact."}}
        """#)

        XCTAssertEqual(info, CompactInfoWire(preTokens: nil, postTokens: nil, failed: true,
                                             error: "Not enough messages to compact."))
    }

    func testALocalCommandWithNoCompactDetailHasNone() throws {
        XCTAssertNil(try compact(#"{"type":"local_command","command":"context","output":"x"}"#))
        XCTAssertNil(try compact(#"{"type":"local_command","command":"compact","compact":null}"#))
    }

    func testACompactThatIsNotAnObjectIsDroppedInsteadOfFailingTheOrigin() throws {
        for bad in [#""lots""#, "42", "true", "[1,2]"] {
            let decoded = try origin(#"{"type":"local_command","command":"compact","output":"Compacted","compact":"# + bad + "}")

            XCTAssertEqual(decoded, .localCommand(command: "compact", args: "", output: "Compacted",
                                                  stream: "stdout", truncated: false, compact: nil), bad)
        }
    }

    func testCompactFieldsOfTheWrongTypeReadAsMissingAndNeverThrow() throws {
        let info = try compact(#"""
        {"type":"local_command","command":"compact",
         "compact":{"pre_tokens":"45123","post_tokens":{"n":1},"failed":"yes","error":7}}
        """#)

        XCTAssertEqual(info, CompactInfoWire(preTokens: nil, postTokens: nil, failed: false, error: nil))
    }

    func testOneOddCompactFieldDoesNotCostTheOthers() throws {
        let info = try compact(#"""
        {"type":"local_command","command":"compact","compact":{"pre_tokens":"lots","post_tokens":900,"future":1}}
        """#)

        XCTAssertEqual(info, CompactInfoWire(preTokens: nil, postTokens: 900, failed: false, error: nil))
    }

    func testAnEmptyCompactObjectIsASuccessWithNoNumbers() throws {
        XCTAssertEqual(try compact(#"{"type":"local_command","command":"compact","compact":{}}"#), CompactInfoWire())
    }

    func testACompactRecordRoundTripsThroughEncoding() throws {
        for info in [
            CompactInfoWire(preTokens: 45123, postTokens: 19700),
            CompactInfoWire(failed: true, error: "Not enough messages to compact."),
            CompactInfoWire(preTokens: 10),
            CompactInfoWire(),
        ] {
            let original = TurnOriginWire.localCommand(command: "compact", args: "", output: "Compacted",
                                                       stream: "stdout", truncated: false, compact: info)
            let data = try JSONEncoder().encode(original)
            XCTAssertEqual(try JSONDecoder().decode(TurnOriginWire.self, from: data), original)
        }
    }

    func testEncodingEmitsTheCompactKeyOnlyWhenThereIsCompactDetail() throws {
        func object(_ o: TurnOriginWire) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(o)) as? [String: Any])
        }
        let plain = try object(.localCommand(command: "context", args: "", output: "o", stream: "stdout", truncated: false))
        XCTAssertNil(plain["compact"], "an ordinary record adds no key")

        let withInfo = try object(.localCommand(command: "compact", args: "", output: "o", stream: "stdout",
                                                truncated: false, compact: CompactInfoWire(preTokens: 5, postTokens: 2)))
        let inner = try XCTUnwrap(withInfo["compact"] as? [String: Any])
        XCTAssertEqual(inner["pre_tokens"] as? Int, 5)
        XCTAssertEqual(inner["post_tokens"] as? Int, 2)
        XCTAssertNil(inner["failed"], "failed is written only when true")
    }

    func testATurnCarriesTheCompactDetailOfItsOrigin() throws {
        let decoded = try turn(origin: #"{"type":"local_command","command":"compact","compact":{"pre_tokens":3,"post_tokens":1}}"#)

        XCTAssertEqual(decoded.origin, .localCommand(command: "compact", args: "", output: "", stream: "stdout",
                                                     truncated: false, compact: CompactInfoWire(preTokens: 3, postTokens: 1)))
    }
}
