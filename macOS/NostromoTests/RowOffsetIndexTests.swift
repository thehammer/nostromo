import XCTest

// `RowOffsetIndex` is compiled into this target directly (logic test — no
// host app, no `@testable import`), the same idiom as `CodeDocumentTests`
// and `DiffDocumentTests`. `CodeDocument` and the `DiffDocument` family are
// also compiled in directly, and are used here only as a cross-check: the
// invariant this file exists to nail down is that `RowOffsetIndex`'s
// offset arithmetic never drifts from the two document types that build
// their row lengths for it.

/// Behavioural coverage for `RowOffsetIndex` — the offset→row binary search
/// that both `CodeContentView`'s visible-range calculation and
/// `LineNumberRulerView`'s gutter numbering depend on (W2 —
/// curated-agent-views). An off-by-one here numbers the gutter wrong for
/// every real file on screen, silently.
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

    // MARK: 33. Cross-check against DiffDocument — the same invariant, flat rows

    private func contextLine(oldN: Int?, newN: Int?, text: String) -> DiffLineModel {
        DiffLineModel(kind: .context, oldN: oldN, newN: newN, text: text)
    }
    private func addedLine(newN: Int, text: String) -> DiffLineModel {
        DiffLineModel(kind: .added, oldN: nil, newN: newN, text: text)
    }
    private func removedLine(oldN: Int, text: String) -> DiffLineModel {
        DiffLineModel(kind: .removed, oldN: oldN, newN: nil, text: text)
    }
    private func metaLine(text: String) -> DiffLineModel {
        DiffLineModel(kind: .meta, oldN: nil, newN: nil, text: text)
    }

    func testRowOffsetIndexAgreesWithDiffDocumentCharacterRangesForEveryRow() {
        let file1 = DiffFileModel(
            path: "a.rs", status: .modified, additions: 1, deletions: 1,
            hunks: [DiffHunkModel(header: "@@ -1,3 +1,3 @@", oldStart: 1, newStart: 1, lines: [
                contextLine(oldN: 1, newN: 1, text: "unchanged"),
                addedLine(newN: 2, text: "a rather longer added line of text"),
                removedLine(oldN: 2, text: "old"),
            ])]
        )
        let file2 = DiffFileModel(
            path: "b.rs", status: .modified, additions: 0, deletions: 0,
            hunks: [DiffHunkModel(header: "@@ -5,2 +5,2 @@", oldStart: 5, newStart: 5, lines: [
                contextLine(oldN: 5, newN: 5, text: "same"),
                metaLine(text: "\\ No newline at end of file"),
            ])]
        )
        let payload = DiffPayload(repo: "acme/web", number: 7, files: [file1, file2], tooLarge: false, changedFiles: 2)
        let doc = DiffDocument(payload: payload)
        let index = RowOffsetIndex(rowLengths: doc.rows.map { $0.text.utf16.count })

        for row in doc.rows.indices {
            let range = doc.characterRange(ofRow: row)!
            XCTAssertEqual(
                index.row(containingOffset: range.location),
                row,
                "row \(row)'s start offset must resolve back to itself"
            )
        }
    }

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
