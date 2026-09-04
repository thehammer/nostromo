import XCTest
@testable import NostromoKit

// Ported from `macOS/NostromoTests/RowOffsetIndexTests.swift`
// (ios-curated-view-parity W7), with one deliberate omission: macOS's file
// carries a tenth test,
// `testRowOffsetIndexAgreesWithDiffDocumentCharacterRangesForEveryRow`, which
// cross-checks `RowOffsetIndex` against `DiffDocument`. `DiffDocument` is
// `pr_diff` machinery — out of scope for this wedge (W8 brings it to
// NostromoKit) — and porting that one test would require porting a type this
// wedge's plan explicitly defers. The nine tests that exercise
// `RowOffsetIndex` on its own, and its cross-check against `CodeDocument`
// (this wedge's own type), are ported verbatim below; the tenth is left for
// W8 to add alongside `DiffDocument` itself. See the PR body.

/// Behavioural coverage for `RowOffsetIndex` — the offset→row binary search
/// shared by iOS and macOS's gutter/scroll-range arithmetic (W2 —
/// curated-agent-views; ported to NostromoKit in ios-curated-view-parity W7).
/// An off-by-one here numbers the gutter wrong for every real file on
/// screen, silently.
final class RowOffsetIndexTests: XCTestCase {

    // MARK: 27. init(rowLengths:) builds the right cumulative offsets

    func testInitFromRowLengthsBuildsCumulativeOffsetsUnderTheNewlineTerminatorConvention() {
        // "aaaaa\nbbbb\nccccc" shaped: rows of length 5, 4, 5 — each row's
        // start is the previous start plus its length plus one for the "\n".
        let index = RowOffsetIndex(rowLengths: [5, 4, 5])
        XCTAssertEqual(index.count, 3)
        XCTAssertEqual(index[0], 0)
        XCTAssertEqual(index[1], 6)
        XCTAssertEqual(index[2], 11)
    }

    func testInitFromRowLengthsHandlesAZeroLengthRowAsAnEmptyLine() {
        // A zero-length row (an empty line) still consumes exactly one
        // offset slot for its terminator, same as any other row.
        let index = RowOffsetIndex(rowLengths: [0, 3, 0])
        XCTAssertEqual(index.count, 3)
        XCTAssertEqual(index[0], 0)
        XCTAssertEqual(index[1], 1)
        XCTAssertEqual(index[2], 5)
    }

    // MARK: 28. row(containingOffset:) at every boundary

    func testRowContainingOffsetAtEveryRowAndTerminatorBoundary() {
        // Rows of length 5, 4, 5 → starts [0, 6, 11]:
        //   row 0 spans offsets 0...4 (content) then 5 (its "\n" terminator)
        //   row 1 spans offsets 6...9 (content) then 10 (its "\n" terminator)
        //   row 2 spans offsets 11...15 (content), and has no terminator of
        //   its own (it's the last row).
        let index = RowOffsetIndex(rowLengths: [5, 4, 5])

        // First offset of each row.
        XCTAssertEqual(index.row(containingOffset: 0), 0)
        XCTAssertEqual(index.row(containingOffset: 6), 1)
        XCTAssertEqual(index.row(containingOffset: 11), 2)

        // Last content offset of each row.
        XCTAssertEqual(index.row(containingOffset: 4), 0)
        XCTAssertEqual(index.row(containingOffset: 9), 1)
        XCTAssertEqual(index.row(containingOffset: 15), 2)

        // The terminator offset between two rows belongs to the row it
        // terminates, not the row that follows it: offset 5 is row 0's "\n",
        // one short of row 1's start (6), so it must still resolve to row 0.
        // Likewise offset 10 is row 1's "\n", one short of row 2's start (11).
        XCTAssertEqual(index.row(containingOffset: 5), 0,
                       "a row's own terminator offset belongs to that row, not the next one")
        XCTAssertEqual(index.row(containingOffset: 10), 1,
                       "a row's own terminator offset belongs to that row, not the next one")
    }

    // MARK: 29. Past-EOF offsets clamp to the last row, not a crash

    func testOffsetPastTheEndOfTheLastRowReturnsTheLastRow() {
        let index = RowOffsetIndex(rowLengths: [5, 4, 5])
        XCTAssertEqual(index.row(containingOffset: 16), 2, "one past the last row's content")
        XCTAssertEqual(index.row(containingOffset: 999), 2, "far past EOF must still return the last row")
    }

    // MARK: 30. An empty index is well-defined, not a crash waiting to happen

    func testEmptyIndexReturnsRowZeroForAnyOffsetAndReportsEmpty() {
        let index = RowOffsetIndex(rowLengths: [])
        XCTAssertTrue(index.isEmpty)
        XCTAssertEqual(index.count, 0)
        XCTAssertEqual(index.row(containingOffset: 0), 0)
        XCTAssertEqual(index.row(containingOffset: 500), 0)
    }

    // MARK: 31. A single-row index always resolves to row 0

    func testSingleRowIndexReturnsRowZeroForEveryOffset() {
        let index = RowOffsetIndex(rowLengths: [7])
        XCTAssertFalse(index.isEmpty)
        XCTAssertEqual(index.count, 1)
        XCTAssertEqual(index.row(containingOffset: 0), 0)
        XCTAssertEqual(index.row(containingOffset: 3), 0)
        XCTAssertEqual(index.row(containingOffset: 999), 0)
    }

    // MARK: 32. Cross-check against CodeDocument — the gutter's real invariant

    func testRowOffsetIndexAgreesWithCodeDocumentCharacterRangesForEveryLine() {
        // Includes a blank line (empty row) and lines of differing length,
        // the same shapes a real file mixes together.
        let text = "one\ntwo\n\nfour\nfive"
        let doc = CodeDocument(path: "f", revision: "working", firstLine: 1, text: text)
        let index = RowOffsetIndex(rowLengths: doc.lines.map { $0.utf16.count })

        for line in doc.firstLine...doc.lastLine {
            let range = doc.characterRange(ofLine: line)!
            XCTAssertEqual(
                index.row(containingOffset: range.location),
                line - doc.firstLine,
                "line \(line)'s start offset must resolve back to its own row"
            )
        }
    }

    func testRowOffsetIndexAgreesWithCodeDocumentWhenFirstLineIsNotOne() {
        // A windowed read (e.g. firstLine: 100) numbers lines starting well
        // above 1; the row index itself is still 0-based, so the invariant
        // must subtract `firstLine`, not assume line number == row.
        let text = "alpha\nbeta\n\ndelta"
        let doc = CodeDocument(path: "f", revision: "working", firstLine: 100, text: text)
        let index = RowOffsetIndex(rowLengths: doc.lines.map { $0.utf16.count })

        for line in doc.firstLine...doc.lastLine {
            let range = doc.characterRange(ofLine: line)!
            XCTAssertEqual(index.row(containingOffset: range.location), line - doc.firstLine)
        }
    }

    // MARK: 33. Cross-check against DiffDocument — deferred to W8

    // Deliberately not ported: `DiffDocument` is `pr_diff` machinery this
    // wedge's plan explicitly puts out of scope (W8). See this file's header
    // comment.

    // MARK: 34. UTF-16 correctness — an emoji row stays aligned with NSString

    func testEmojiRowContributesItsUTF16LengthKeepingOffsetsAlignedWithNSString() {
        // "é" and "👋" are exactly where `String.count` and UTF-16 length
        // diverge (a combining/precomposed accent and a surrogate pair).
        let line0 = "héllo👋"
        let line1 = "next"
        XCTAssertNotEqual(line0.utf16.count, line0.count,
                          "test setup sanity: this string must actually diverge between UTF-16 length and Character count")

        let index = RowOffsetIndex(rowLengths: [line0.utf16.count, line1.utf16.count])

        let combined = line0 + "\n" + line1
        let ns = combined as NSString
        let expectedLine1Start = ns.range(of: line1).location

        XCTAssertEqual(index[0], 0)
        XCTAssertEqual(index[1], expectedLine1Start,
                       "row 1's start offset must match NSString's UTF-16 measurement of the emoji-bearing row 0 plus its terminator")

        XCTAssertEqual(index.row(containingOffset: 0), 0)
        XCTAssertEqual(index.row(containingOffset: expectedLine1Start - 1), 0,
                       "the last UTF-16 unit before row 1 (row 0's terminator) still belongs to row 0")
        XCTAssertEqual(index.row(containingOffset: expectedLine1Start), 1)
    }
}
