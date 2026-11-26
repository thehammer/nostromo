// PushDetailWireTests.swift
//
// `push_detail` (W16): the phone's request and the primary's answer. The decoder is the Notification
// Service Extension's trust boundary for what the daemon sends back, so these tests pin both the
// happy path (a reply the daemon really sends) and the hostile one: bounded input, unknown fields
// ignored, anything that is not exactly a `push_detail` for us is nil and never a crash, and the text
// is never longer than 140 characters. The fuzz tests use fixed seeds only.

import XCTest
@testable import NostromoKit

final class PushDetailWireTests: XCTestCase {

    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    private func parse(_ json: String) -> PushDetailWire? { PushDetailWire.parse(Data(json.utf8)) }

    // MARK: - The request

    func testThePushDetailRequestEncodesTheDaemonsShape() throws {
        let json = try object(ClientPushDetail(itemRef: "a1b2c3d4e5f60708"))
        XCTAssertEqual(json["type"] as? String, "push_detail")
        XCTAssertEqual(json["item_ref"] as? String, "a1b2c3d4e5f60708")
        XCTAssertEqual(Set(json.keys), ["type", "item_ref"], "the request carries nothing else")
    }

    func testPushDetailIsAPairedDeviceVerb() {
        XCTAssertTrue(OutboundPolicy.allows(type: "push_detail"))
        XCTAssertTrue(OutboundPolicy.pairedDeviceTypes.contains("push_detail"))
    }

    // MARK: - The answer

    func testAFullAnswerParses() throws {
        let detail = try XCTUnwrap(parse("""
        {"type":"push_detail","item_ref":"a1b2c3d4e5f60708","waiting":true,
         "text":"Which database should the migration use?","host":"sendai"}
        """))
        XCTAssertEqual(detail.itemRef, "a1b2c3d4e5f60708")
        XCTAssertTrue(detail.waiting)
        XCTAssertEqual(detail.text, "Which database should the migration use?")
        XCTAssertEqual(detail.host, "sendai")
    }

    func testTextAndHostAreOptional() throws {
        let detail = try XCTUnwrap(parse(#"{"type":"push_detail","item_ref":"x","waiting":false}"#))
        XCTAssertEqual(detail.itemRef, "x")
        XCTAssertFalse(detail.waiting)
        XCTAssertNil(detail.text)
        XCTAssertNil(detail.host)
    }

    func testUnknownFieldsAreIgnored() throws {
        let detail = try XCTUnwrap(parse("""
        {"type":"push_detail","item_ref":"x","waiting":true,"text":"hello",
         "future_field":{"nested":[1,2,3]},"another":null}
        """))
        XCTAssertEqual(detail.text, "hello")
    }

    func testTextLongerThanTheCapIsCutAtTheCap() throws {
        XCTAssertEqual(PushDetailWire.maxTextCharacters, 140)
        let long = String(repeating: "é", count: 141)
        let detail = try XCTUnwrap(PushDetailWire.parse(detailFrame(itemRef: "x", text: long)))
        XCTAssertEqual(detail.text?.count, 140)
        let exact = String(repeating: "a", count: 140)
        XCTAssertEqual(try XCTUnwrap(PushDetailWire.parse(detailFrame(itemRef: "x", text: exact))).text, exact)
    }

    // MARK: - Not ours

    func testAnythingThatIsNotAPushDetailForUsIsNil() {
        XCTAssertNil(parse(#"{"type":"welcome","item_ref":"x","waiting":true}"#), "wrong type")
        XCTAssertNil(parse(#"{"item_ref":"x","waiting":true}"#), "no type")
        XCTAssertNil(parse(#"{"type":"push_detail","waiting":true}"#), "no item_ref")
        XCTAssertNil(parse(#"{"type":"push_detail","item_ref":"x"}"#), "no waiting")
        XCTAssertNil(parse(#"{"type":"push_detail","item_ref":7,"waiting":true}"#), "item_ref is not a string")
        XCTAssertNil(parse(#"{"type":"push_detail","item_ref":"x","waiting":"yes"}"#), "waiting is not a bool")
        XCTAssertNil(parse(#"["push_detail"]"#), "not an object")
        XCTAssertNil(parse("not json"))
        XCTAssertNil(PushDetailWire.parse(Data()))
    }

    func testAnOptionalFieldOfTheWrongTypeIsWithheldNotTrusted() throws {
        let detail = try XCTUnwrap(parse(#"{"type":"push_detail","item_ref":"x","waiting":true,"text":42,"host":["a"]}"#))
        XCTAssertNil(detail.text)
        XCTAssertNil(detail.host)
    }

    func testAFrameOverTheSizeCapIsNilAndOneAtTheCapIsKept() throws {
        XCTAssertEqual(PushDetailWire.maxFrameBytes, 16 * 1024)
        var frame = detailFrame(itemRef: "x", text: "hello")
        frame.append(Data(repeating: 0x20, count: PushDetailWire.maxFrameBytes - frame.count))
        XCTAssertEqual(frame.count, PushDetailWire.maxFrameBytes)
        XCTAssertEqual(PushDetailWire.parse(frame)?.text, "hello", "exactly at the cap is accepted")
        frame.append(0x20)
        XCTAssertNil(PushDetailWire.parse(frame), "one byte over is not ours")
    }

    // MARK: - Through the frame decoder

    private func decode(_ data: Data) -> ServerMsg { ServerMsg.decode(from: data) }

    func testAPushDetailFrameDecodesToPushDetail() {
        let msg = decode(detailFrame(itemRef: "a1b2", text: "Which database?"))
        guard case .pushDetail(let detail) = msg else { return XCTFail("\(msg)") }
        XCTAssertEqual(detail.itemRef, "a1b2")
        XCTAssertEqual(detail.text, "Which database?")
        XCTAssertTrue(detail.waiting)
    }

    func testAMalformedPushDetailFrameDecodesToUnknown() {
        let malformed = [
            #"{"type":"push_detail"}"#,
            #"{"type":"push_detail","item_ref":"x"}"#,
            #"{"type":"push_detail","item_ref":9,"waiting":true}"#,
            #"{"type":"push_detail","item_ref":"x","waiting":"true"}"#,
        ]
        for json in malformed {
            let msg = decode(Data(json.utf8))
            if case .unknown = msg { continue }
            XCTFail("\(json) decoded to \(msg)")
        }
    }

    // MARK: - Fuzz: never a crash, never an over-long text

    /// SplitMix64: a fixed seed gives the same bytes on every run.
    private struct PushFuzzGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Whatever `parse` makes of `data`, it is nil or its text is within the cap.
    private func assertNilOrBounded(_ data: Data, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        guard let detail = PushDetailWire.parse(data) else { return }
        if let text = detail.text {
            XCTAssertLessThanOrEqual(text.count, PushDetailWire.maxTextCharacters, label, file: file, line: line)
        }
    }

    private var validFrame: Data { detailFrame(itemRef: "a1b2c3d4e5f60708", text: "Which database?", host: "sendai") }

    func testEveryTruncationOfAValidFrameIsNil() {
        let frame = validFrame
        XCTAssertNotNil(PushDetailWire.parse(frame))
        for length in 0..<frame.count {
            XCTAssertNil(PushDetailWire.parse(frame.prefix(length)), "prefix of \(length) bytes")
        }
    }

    func testAWrongTypeForAnyFieldNeverCrashesAndARequiredOneIsNil() {
        let valid: [(key: String, raw: String)] = [
            ("type", "\"push_detail\""), ("item_ref", "\"item-1\""), ("waiting", "true"),
            ("text", "\"hello\""), ("host", "\"sendai\""),
        ]
        func frame(replacing key: String, with raw: String) -> Data {
            var members: [String] = []
            for member in valid {
                let value = member.key == key ? raw : member.raw
                members.append("\"" + member.key + "\":" + value)
            }
            return Data(("{" + members.joined(separator: ",") + "}").utf8)
        }
        let wrong = ["null", "7", "1.5", "true", "false", "\"str\"", "[]", "{}", "[[1]]", "{\"a\":{\"b\":1}}"]
        for (key, _) in valid {
            for raw in wrong {
                let data = frame(replacing: key, with: raw)
                assertNilOrBounded(data, "\(key)=\(raw)")
                switch key {
                case "type":
                    XCTAssertNil(PushDetailWire.parse(data), "type=\(raw)")
                case "item_ref":
                    if raw != "\"str\"" { XCTAssertNil(PushDetailWire.parse(data), "item_ref=\(raw)") }
                case "waiting":
                    if ["null", "\"str\"", "[]", "{}", "[[1]]", "{\"a\":{\"b\":1}}"].contains(raw) {
                        XCTAssertNil(PushDetailWire.parse(data), "waiting=\(raw)")
                    }
                case "text":
                    if raw != "\"str\"" { XCTAssertNil(PushDetailWire.parse(data)?.text, "text=\(raw)") }
                default:
                    break
                }
            }
        }
    }

    func testHostileShapesNeverCrashAndNeverYieldAnOverLongText() {
        let nestedArrays = String(repeating: "[", count: 8_000) + String(repeating: "]", count: 8_000)
        let nestedField = String(repeating: "[", count: 200) + String(repeating: "]", count: 200)
        let hugeText = String(repeating: "x", count: 16_000)
        let head = Data(#"{"type":"push_detail","item_ref":"x","waiting":true,"text":"ok"#.utf8)
        let tail = Data(#""}"#.utf8)
        var nulAfterValid = validFrame
        nulAfterValid.append(0x00)
        var invalidUTF8 = head
        invalidUTF8.append(Data([0xFF, 0xFE, 0xC0, 0xAF]))
        invalidUTF8.append(tail)
        var truncatedMultibyte = head
        truncatedMultibyte.append(Data([0xE2, 0x82]))
        truncatedMultibyte.append(tail)
        var withBOM = Data([0xEF, 0xBB, 0xBF])
        withBOM.append(validFrame)
        let cases: [(String, Data)] = [
            ("empty", Data()),
            ("null", Data("null".utf8)),
            ("number", Data("42".utf8)),
            ("string", Data("\"push_detail\"".utf8)),
            ("empty object", Data("{}".utf8)),
            ("deeply nested arrays", Data(nestedArrays.utf8)),
            ("deeply nested unknown field",
             Data(#"{"type":"push_detail","item_ref":"x","waiting":true,"extra":\#(nestedField)}"#.utf8)),
            ("deeply nested text", Data(#"{"type":"push_detail","item_ref":"x","waiting":true,"text":\#(nestedField)}"#.utf8)),
            ("nested garbage object",
             Data(#"{"type":"push_detail","item_ref":{"a":{"b":[{"c":null}]}},"waiting":[true],"text":{"t":1}}"#.utf8)),
            ("text just under the frame cap", Data(#"{"type":"push_detail","item_ref":"x","waiting":true,"text":"\#(hugeText)"}"#.utf8)),
            ("text over the frame cap",
             Data(#"{"type":"push_detail","item_ref":"x","waiting":true,"text":"\#(hugeText)\#(hugeText)"}"#.utf8)),
            ("huge item_ref", Data(#"{"type":"push_detail","item_ref":"\#(hugeText)","waiting":true}"#.utf8)),
            ("escaped NUL in text", Data(#"{"type":"push_detail","item_ref":"x","waiting":true,"text":"a\u0000b"}"#.utf8)),
            ("lone surrogate escape", Data(#"{"type":"push_detail","item_ref":"x","waiting":true,"text":"\ud800 tail"}"#.utf8)),
            ("raw NUL byte", Data([0x7B, 0x00, 0x7D])),
            ("NUL after a valid frame", nulAfterValid),
            ("invalid UTF-8 in text", invalidUTF8),
            ("truncated multi-byte sequence", truncatedMultibyte),
            ("byte order mark", withBOM),
        ]
        for (label, data) in cases { assertNilOrBounded(data, label) }

        XCTAssertNil(PushDetailWire.parse(Data(nestedArrays.utf8)))
        let justUnder = cases.first(where: { $0.0 == "text just under the frame cap" })?.1 ?? Data()
        XCTAssertEqual(PushDetailWire.parse(justUnder)?.text?.count, PushDetailWire.maxTextCharacters)
        let over = cases.first(where: { $0.0 == "text over the frame cap" })?.1 ?? Data()
        XCTAssertNil(PushDetailWire.parse(over))
    }

    func testRandomByteBlobsFromAFixedSeedNeverCrash() {
        var rng = PushFuzzGenerator(seed: 16_000_001)
        for round in 0..<500 {
            let length = Int.random(in: 0...300, using: &rng)
            var bytes: [UInt8] = []
            for _ in 0..<length { bytes.append(UInt8.random(in: 0...255, using: &rng)) }
            assertNilOrBounded(Data(bytes), "blob \(round)")
        }
    }

    func testMutatedValidFramesFromAFixedSeedNeverCrash() {
        var rng = PushFuzzGenerator(seed: 16_000_002)
        let base = [UInt8](detailFrame(itemRef: "a1b2c3d4e5f60708", text: String(repeating: "q", count: 160)))
        for round in 0..<2_000 {
            var bytes = base
            for _ in 0..<Int.random(in: 1...4, using: &rng) where !bytes.isEmpty {
                let index = Int.random(in: 0..<bytes.count, using: &rng)
                switch Int.random(in: 0..<4, using: &rng) {
                case 0:
                    bytes[index] = UInt8.random(in: 0...255, using: &rng)
                case 1:
                    let end = min(bytes.count, index + Int.random(in: 1...8, using: &rng))
                    bytes.removeSubrange(index..<end)
                case 2:
                    bytes.insert(UInt8.random(in: 0...255, using: &rng), at: index)
                default:
                    let end = min(bytes.count, index + Int.random(in: 1...16, using: &rng))
                    bytes.insert(contentsOf: bytes[index..<end], at: index)
                }
            }
            assertNilOrBounded(Data(bytes), "mutation \(round)")
        }
    }
}
