import XCTest
@testable import NostromoKit

// Staged-command text (T4). The refused-character set is the daemon's `is_invisible`, held to ONE list:
// `tests/fixtures/tracker/invisible-chars.txt` (the Rust side reads the same file, for every code point).
final class TrackerCommandTextTests: XCTestCase {

    /// Every range the fixture lists.
    private func listedRanges() throws -> [ClosedRange<UInt32>] {
        try TrackerFixtures.fixtureText("invisible-chars.txt").split(separator: "\n")
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }
            .map { line in
                let parts = line.split(separator: "-")
                let lo = UInt32(parts[0], radix: 16)!
                let hi = parts.count > 1 ? UInt32(parts[1], radix: 16)! : lo
                return lo...hi
            }
    }

    func testEveryCodePointTheDaemonRefusesIsDroppedFromWhatTheMacDrawsAndCopies() throws {
        let ranges = try listedRanges()
        XCTAssertGreaterThan(ranges.count, 20)
        var checked = 0
        for range in ranges {
            for value in range {
                guard let scalar = Unicode.Scalar(value), scalar != "\n", scalar != "\t" else { continue }
                XCTAssertTrue(TrackerCommandText.isInvisible(scalar), "U+\(String(value, radix: 16)) is not in the Mac's set")
                XCTAssertEqual(TrackerCommandText.displayed("a\(scalar)b"), "ab",
                               "U+\(String(value, radix: 16)) was drawn")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 4_000)
    }

    func testTheMacRefusesNothingBeyondTheSharedListInTheBasicPlane() throws {
        let ranges = try listedRanges()
        for value in UInt32(0x20)...UInt32(0xFFFF) {
            guard let scalar = Unicode.Scalar(value) else { continue }
            let listed = ranges.contains { $0.contains(value) }
            if !listed && TrackerCommandText.isInvisible(scalar) {
                XCTFail("U+\(String(value, radix: 16)) is in the Mac's set but not the shared list")
            }
        }
    }

    func testTheNineCharactersTheMacOnceKeptAreDropped() {
        for value: UInt32 in [0xFE00, 0xFE0F, 0xE0101, 0xE01EF, 0x17B4, 0x180B, 0x180F, 0x2065, 0xFFF0] {
            let scalar = Unicode.Scalar(value)!
            XCTAssertEqual(TrackerCommandText.displayed("ls\(scalar)-la"), "ls-la", "U+\(String(value, radix: 16))")
        }
    }

    func testANewlineAndATabSurvive() {
        XCTAssertEqual(TrackerCommandText.displayed("a\n\tb"), "a\n\tb")
    }

    func testACommandOverTheLimitIsReportedAsCutAndOneAtTheLimitIsNot() {
        let limit = TrackerCommandText.maxScalars
        XCTAssertFalse(TrackerCommandText.wasCut(String(repeating: "x", count: limit)))
        XCTAssertTrue(TrackerCommandText.wasCut(String(repeating: "x", count: limit + 1)))
        XCTAssertEqual(TrackerCommandText.displayed(String(repeating: "x", count: limit + 1)).unicodeScalars.count, limit)
        // Refused characters do not count toward the limit.
        XCTAssertFalse(TrackerCommandText.wasCut(String(repeating: "x", count: limit) + "\u{200B}\u{FE0F}"))
    }

    func testTheWireCarriesTheDaemonsWithheldFlagAndDefaultsToFalse() throws {
        func decode(_ extra: String) throws -> TrackerItemWire {
            let json = "{\"id\":\"a\",\"kind\":\"command\"\(extra)}"
            return try JSONDecoder().decode(TrackerItemWire.self, from: Data(json.utf8))
        }
        XCTAssertTrue(try decode(",\"command_withheld\":true").commandWithheld)
        XCTAssertFalse(try decode("").commandWithheld)
    }
}
