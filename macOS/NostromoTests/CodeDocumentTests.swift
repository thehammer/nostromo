import XCTest

// `CodeDocument` and `CodePayload` are compiled into this target directly
// (logic test — no host app, no `@testable import`), the same idiom as
// `PaneContentWireEqualityTests`.

/// Behavioural coverage for `CodeDocument` — the line/character arithmetic a
/// `code` pane's gutter, scroll, and emphasis all depend on (W2 —
/// curated-agent-views).
final class CodeDocumentTests: XCTestCase {

    // MARK: 1. Splitting

    func testEmptyStringIsOneEmptyLine() {
        let doc = CodeDocument(path: "f", revision: "working", firstLine: 1, text: "")
        XCTAssertEqual(doc.lineCount, 1)
        XCTAssertEqual(doc.lastLine, 1)
        XCTAssertEqual(doc.lines, [""])
    }

    func testSingleLineWithNoNewlineIsOneLine() {
        let doc = CodeDocument(path: "f", revision: "working", firstLine: 1, text: "a")
        XCTAssertEqual(doc.lineCount, 1)
        XCTAssertEqual(doc.lastLine, 1)
        XCTAssertEqual(doc.lines, ["a"])
    }

    func testTwoLinesWithNoTrailingNewlineIsTwoLines() {
        let doc = CodeDocument(path: "f", revision: "working", firstLine: 1, text: "a\nb")
        XCTAssertEqual(doc.lineCount, 2)
        XCTAssertEqual(doc.lastLine, 2)
        XCTAssertEqual(doc.lines, ["a", "b"])
    }

    func testTrailingNewlineIsATerminatorNotAPhantomLine() {
        let doc = CodeDocument(path: "f", revision: "working", firstLine: 1, text: "a\nb\n")
        XCTAssertEqual(doc.lineCount, 2, "a trailing newline must not produce a phantom third line")
        XCTAssertEqual(doc.lastLine, 2)
        XCTAssertEqual(doc.lines, ["a", "b"])
    }

    // MARK: 2. `text` round-trips

    func testTextRoundTripsMinusAnyTrailingNewline() {
        let withTrailing = CodeDocument(path: "f", revision: "working", firstLine: 1, text: "alpha\nbeta\ngamma\n")
        XCTAssertEqual(withTrailing.text, "alpha\nbeta\ngamma")

        let withoutTrailing = CodeDocument(path: "f", revision: "working", firstLine: 1, text: "alpha\nbeta\ngamma")
        XCTAssertEqual(withoutTrailing.text, "alpha\nbeta\ngamma")
    }

    // MARK: 3. characterRange(ofLine:) — concrete arithmetic

    func testCharacterRangeOfLineReturnsConcreteOffsetsForAKnownDocument() {
        // "alpha\nbeta\ngamma": alpha=5 chars, \n, beta=4 chars, \n, gamma=5 chars.
        let doc = CodeDocument(path: "f", revision: "working", firstLine: 1, text: "alpha\nbeta\ngamma")
        XCTAssertEqual(doc.characterRange(ofLine: 1), NSRange(location: 0, length: 5))
        XCTAssertEqual(doc.characterRange(ofLine: 2), NSRange(location: 6, length: 4))
        XCTAssertEqual(doc.characterRange(ofLine: 3), NSRange(location: 11, length: 5))
    }

    // MARK: 4. Out-of-range line lookups return nil, not a clamped range

    func testCharacterRangeOfLineZeroIsNil() {
        let doc = CodeDocument(path: "f", revision: "working", firstLine: 1, text: "alpha\nbeta")
        XCTAssertNil(doc.characterRange(ofLine: 0))
    }

    func testCharacterRangeOfLinePastEOFIsNilNotClamped() {
        let doc = CodeDocument(path: "f", revision: "working", firstLine: 1, text: "alpha\nbeta")
        XCTAssertNil(doc.characterRange(ofLine: 3), "line 3 of a 2-line document must be nil, not clamped to the last line")
        XCTAssertNil(doc.characterRange(ofLine: 9000))
    }

    // MARK: 5. characterRange(fromLine:toLine:)

    func testCharacterRangeFromLineToLineSpansTerminators() {
        let doc = CodeDocument(path: "f", revision: "working", firstLine: 1, text: "alpha\nbeta\ngamma")
        // "alpha\nbeta" — 5 + 1 (terminator) + 4 = 10.
        XCTAssertEqual(doc.characterRange(fromLine: 1, toLine: 2), NSRange(location: 0, length: 10))
    }

    func testCharacterRangeFromLineToLineIsNilForAnInvertedRange() {
        let doc = CodeDocument(path: "f", revision: "working", firstLine: 1, text: "alpha\nbeta\ngamma")
        XCTAssertNil(doc.characterRange(fromLine: 2, toLine: 1))
    }

    func testCharacterRangeFromLineToLineIsNilWhenEitherEndIsPastEOF() {
        let doc = CodeDocument(path: "f", revision: "working", firstLine: 1, text: "alpha\nbeta\ngamma")
        XCTAssertNil(doc.characterRange(fromLine: 1, toLine: 4))
        XCTAssertNil(doc.characterRange(fromLine: 0, toLine: 2))
    }

    // MARK: 6. UTF-16 correctness

    func testCharacterRangesAreMeasuredInUTF16CodeUnitsMatchingNSString() {
        // "héllo👋" — the combining/accented "é" and the emoji are exactly the
        // cases where `String.count` and UTF-16 length diverge. Comparing
        // against `NSString` range arithmetic on the identical string is the
        // ground truth `NSTextView`/`NSRange` themselves use.
        let text = "héllo👋\nnext"
        let doc = CodeDocument(path: "f", revision: "working", firstLine: 1, text: text)
        let ns = text as NSString

        let expectedLine1 = ns.range(of: "héllo👋")
        let expectedLine2 = ns.range(of: "next")
        XCTAssertNotEqual(expectedLine1.length, "héllo👋".count,
                          "test setup sanity: this string must actually diverge between UTF-16 length and Character count")

        XCTAssertEqual(doc.characterRange(ofLine: 1), expectedLine1)
        XCTAssertEqual(doc.characterRange(ofLine: 2), expectedLine2)
        XCTAssertEqual(doc.characterRange(fromLine: 1, toLine: 2), NSRange(location: 0, length: ns.length))
    }

    // MARK: 7. A windowed read (firstLine > 1)

    func testFirstLineGreaterThanOneShiftsContainsLastLineAndLineNumberForRow() {
        let doc = CodeDocument(path: "f", revision: "working", firstLine: 100, text: "a\nb\nc")

        XCTAssertFalse(doc.contains(line: 99))
        XCTAssertTrue(doc.contains(line: 100))
        XCTAssertTrue(doc.contains(line: 102))
        XCTAssertFalse(doc.contains(line: 103))
        XCTAssertEqual(doc.lastLine, 102)

        XCTAssertEqual(doc.lineNumber(forRow: 0), 100)
        XCTAssertEqual(doc.lineNumber(forRow: 2), 102)
        XCTAssertNil(doc.lineNumber(forRow: 3))
        XCTAssertNil(doc.lineNumber(forRow: -1))

        XCTAssertEqual(doc.characterRange(ofLine: 100), NSRange(location: 0, length: 1))
    }

    // MARK: 8. init(payload:) maps CodePayload faithfully

    func testInitFromPayloadMapsEveryFieldFaithfully() {
        let payload = CodePayload(path: "src/main.rs", revision: "deadbeef", firstLine: 42, text: "x\ny\nz")
        let doc = CodeDocument(payload: payload)

        XCTAssertEqual(doc.path, "src/main.rs")
        XCTAssertEqual(doc.revision, "deadbeef")
        XCTAssertEqual(doc.firstLine, 42)
        XCTAssertEqual(doc.lines, ["x", "y", "z"])
        XCTAssertEqual(doc.lineCount, 3)
        XCTAssertEqual(doc.lastLine, 44)
    }
}
