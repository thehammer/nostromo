import XCTest

// `DiffDocument`, `DiffRow`, `DiffPayload`, `DiffFileModel`, `DiffHunkModel`,
// `DiffLineModel` are compiled into this target directly (logic test — no
// host app, no `@testable import`), the same idiom as
// `PaneContentWireEqualityTests`.

/// Behavioural coverage for `DiffDocument` — the flattening and row-addressing
/// arithmetic a `diff` pane's gutter, scroll, and emphasis all depend on (W2 —
/// curated-agent-views).
final class DiffDocumentTests: XCTestCase {

    // MARK: - Fixture builders

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

    private func payload(files: [DiffFileModel], tooLarge: Bool = false, changedFiles: Int = 0) -> DiffPayload {
        DiffPayload(repo: "acme/web", number: 7, files: files, tooLarge: tooLarge, changedFiles: changedFiles)
    }

    // MARK: 9. Flattening order

    func testFlatteningProducesFileHeaderThenHunkHeaderThenOneRowPerLinePerFile() {
        let file1 = DiffFileModel(
            path: "a.rs", status: .modified, additions: 1, deletions: 1,
            hunks: [DiffHunkModel(header: "@@ -1,3 +1,3 @@", oldStart: 1, newStart: 1, lines: [
                contextLine(oldN: 1, newN: 1, text: "unchanged"),
                addedLine(newN: 2, text: "new"),
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
        let doc = DiffDocument(payload: payload(files: [file1, file2]))

        XCTAssertEqual(doc.rows.map(\.kind), [
            .fileHeader, .hunkHeader, .context, .added, .removed,
            .fileHeader, .hunkHeader, .context, .meta,
        ])
    }

    // MARK: 10. Marker restoration

    func testRowTextRestoresTheDiffMarkerPerKindAndLeavesMetaVerbatim() {
        let file = DiffFileModel(
            path: "a.rs", status: .modified, additions: 1, deletions: 1,
            hunks: [DiffHunkModel(header: "@@ h @@", oldStart: 1, newStart: 1, lines: [
                contextLine(oldN: 1, newN: 1, text: "unchanged"),
                addedLine(newN: 2, text: "new line"),
                removedLine(oldN: 2, text: "old line"),
                metaLine(text: "\\ No newline at end of file"),
            ])]
        )
        let doc = DiffDocument(payload: payload(files: [file]))
        let rowsByKind = Dictionary(grouping: doc.rows, by: \.kind)

        XCTAssertEqual(rowsByKind[.context]?.first?.text, " unchanged")
        XCTAssertEqual(rowsByKind[.added]?.first?.text, "+new line")
        XCTAssertEqual(rowsByKind[.removed]?.first?.text, "-old line")
        XCTAssertEqual(rowsByKind[.meta]?.first?.text, "\\ No newline at end of file",
                       "a .meta line's marker IS its content — it must not be prefixed again")
    }

    // MARK: 11. New-side numbering wins when a line exists on both sides

    func testRowIndexResolvesToTheAddedRowWhenTheSameNumberExistsAsBothARemovalAndAnAddition() {
        let file = DiffFileModel(
            path: "a.rs", status: .modified, additions: 1, deletions: 1,
            hunks: [DiffHunkModel(header: "@@ h @@", oldStart: 5, newStart: 5, lines: [
                removedLine(oldN: 5, text: "old5"),
                addedLine(newN: 5, text: "new5"),
            ])]
        )
        let doc = DiffDocument(payload: payload(files: [file]))
        let index = try! XCTUnwrap(doc.rowIndex(forPath: "a.rs", line: 5))
        XCTAssertEqual(doc.rows[index].kind, .added)
        XCTAssertEqual(doc.rows[index].text, "+new5")
    }

    // MARK: 12. A pure deletion resolves to its removal row

    func testRowIndexResolvesToTheRemovalRowForALineThatOnlyExistsOnTheOldSide() {
        let file = DiffFileModel(
            path: "a.rs", status: .modified, additions: 0, deletions: 1,
            hunks: [DiffHunkModel(header: "@@ h @@", oldStart: 7, newStart: 7, lines: [
                removedLine(oldN: 7, text: "gone"),
            ])]
        )
        let doc = DiffDocument(payload: payload(files: [file]))
        let index = try! XCTUnwrap(doc.rowIndex(forPath: "a.rs", line: 7))
        XCTAssertEqual(doc.rows[index].kind, .removed)
        XCTAssertEqual(doc.rows[index].text, "-gone")
    }

    // MARK: 13. Path scoping

    func testRowIndexScopedByPathPicksTheRowInTheRightFileAndNilSearchesAll() {
        let fileA = DiffFileModel(
            path: "a.rs", status: .modified, additions: 1, deletions: 0,
            hunks: [DiffHunkModel(header: "@@ h @@", oldStart: 3, newStart: 3, lines: [
                addedLine(newN: 3, text: "a3"),
            ])]
        )
        let fileB = DiffFileModel(
            path: "b.rs", status: .modified, additions: 1, deletions: 0,
            hunks: [DiffHunkModel(header: "@@ h @@", oldStart: 3, newStart: 3, lines: [
                addedLine(newN: 3, text: "b3"),
            ])]
        )
        let doc = DiffDocument(payload: payload(files: [fileA, fileB]))

        let indexA = try! XCTUnwrap(doc.rowIndex(forPath: "a.rs", line: 3))
        XCTAssertEqual(doc.rows[indexA].path, "a.rs")
        XCTAssertEqual(doc.rows[indexA].text, "+a3")

        let indexB = try! XCTUnwrap(doc.rowIndex(forPath: "b.rs", line: 3))
        XCTAssertEqual(doc.rows[indexB].path, "b.rs")
        XCTAssertEqual(doc.rows[indexB].text, "+b3")

        // `path: nil` must search every row rather than scoping to one file.
        let indexAny = try! XCTUnwrap(doc.rowIndex(forPath: nil, line: 3))
        XCTAssertEqual(doc.rows[indexAny].text, "+a3", "nil path must find *a* matching row across files")
    }

    // MARK: 14. Not-in-the-diff resolves to nil

    func testRowIndexIsNilForALineNotInTheDiffAtAll() {
        let file = DiffFileModel(
            path: "a.rs", status: .modified, additions: 1, deletions: 0,
            hunks: [DiffHunkModel(header: "@@ h @@", oldStart: 1, newStart: 1, lines: [
                addedLine(newN: 1, text: "one"),
            ])]
        )
        let doc = DiffDocument(payload: payload(files: [file]))
        XCTAssertNil(doc.rowIndex(forPath: "a.rs", line: 999))
    }

    // MARK: 15. rowIndices(forPath:from:to:)

    func testRowIndicesIsEmptyRatherThanClampedWhenNothingInTheRangeIsInTheDiff() {
        let file = DiffFileModel(
            path: "a.rs", status: .modified, additions: 1, deletions: 0,
            hunks: [DiffHunkModel(header: "@@ h @@", oldStart: 1, newStart: 1, lines: [
                addedLine(newN: 1, text: "one"),
            ])]
        )
        let doc = DiffDocument(payload: payload(files: [file]))
        XCTAssertEqual(doc.rowIndices(forPath: "a.rs", from: 500, to: 510), [],
                       "no line in [500, 510] is in the diff — this must be empty, not clamped to whatever exists")
    }

    func testRowIndicesReturnsAscendingIndicesForARangeSpanningAHunkBoundary() {
        let file = DiffFileModel(
            path: "a.rs", status: .modified, additions: 4, deletions: 0,
            hunks: [
                DiffHunkModel(header: "@@ h1 @@", oldStart: 10, newStart: 10, lines: [
                    addedLine(newN: 10, text: "ten"),
                    addedLine(newN: 11, text: "eleven"),
                ]),
                DiffHunkModel(header: "@@ h2 @@", oldStart: 50, newStart: 50, lines: [
                    addedLine(newN: 50, text: "fifty"),
                    addedLine(newN: 51, text: "fifty-one"),
                ]),
            ]
        )
        let doc = DiffDocument(payload: payload(files: [file]))
        let indices = doc.rowIndices(forPath: "a.rs", from: 10, to: 51)

        XCTAssertEqual(indices, indices.sorted(), "rows must come back in ascending order across the hunk boundary")
        XCTAssertEqual(indices.map { doc.rows[$0].text }, ["+ten", "+eleven", "+fifty", "+fifty-one"])
    }

    // MARK: 16. characterRange(ofRow:) / characterRange(fromRow:toRow:)

    func testCharacterRangeOfRowReturnsConcreteOffsetsForAKnownPayload() {
        // Row 0 (fileHeader): "f  +0 -0" — 8 UTF-16 units.
        // Row 1 (hunkHeader): "H" — 1 unit.
        // Row 2 (context):    " C" — 2 units (marker + content).
        let file = DiffFileModel(
            path: "f", status: .modified, additions: 0, deletions: 0,
            hunks: [DiffHunkModel(header: "H", oldStart: 1, newStart: 1, lines: [
                contextLine(oldN: 1, newN: 1, text: "C"),
            ])]
        )
        let doc = DiffDocument(payload: payload(files: [file]))
        XCTAssertEqual(doc.rows.map(\.text), ["f  +0 -0", "H", " C"])

        XCTAssertEqual(doc.characterRange(ofRow: 0), NSRange(location: 0, length: 8))
        XCTAssertEqual(doc.characterRange(ofRow: 1), NSRange(location: 9, length: 1))
        XCTAssertEqual(doc.characterRange(ofRow: 2), NSRange(location: 11, length: 2))

        XCTAssertNil(doc.characterRange(ofRow: -1))
        XCTAssertNil(doc.characterRange(ofRow: 3))
    }

    func testCharacterRangeFromRowToRowSpansTerminators() {
        let file = DiffFileModel(
            path: "f", status: .modified, additions: 0, deletions: 0,
            hunks: [DiffHunkModel(header: "H", oldStart: 1, newStart: 1, lines: [
                contextLine(oldN: 1, newN: 1, text: "C"),
            ])]
        )
        let doc = DiffDocument(payload: payload(files: [file]))
        // Rows 0...2 total: 8 + 1(\n) + 1 + 1(\n) + 2 = 13.
        XCTAssertEqual(doc.characterRange(fromRow: 0, toRow: 2), NSRange(location: 0, length: 13))
    }

    // MARK: 17. The large-diff notice

    func testTooLargeDiffProducesANoticeRowNamingTheFileCountInPluralForm() {
        let doc = DiffDocument(payload: payload(files: [], tooLarge: true, changedFiles: 137))
        XCTAssertEqual(doc.rows.first?.kind, .notice)
        let text = try! XCTUnwrap(doc.rows.first?.text)
        XCTAssertTrue(text.contains("137"), "the notice must name how many files changed: \(text)")
        XCTAssertTrue(text.localizedCaseInsensitiveContains("too large"), "the notice must say the diff was gated: \(text)")
        XCTAssertTrue(text.contains("137 files"), "137 changed files must use the plural noun: \(text)")
    }

    func testTooLargeDiffUsesSingularWordingForOneChangedFile() {
        let doc = DiffDocument(payload: payload(files: [], tooLarge: true, changedFiles: 1))
        let text = try! XCTUnwrap(doc.rows.first?.text)
        XCTAssertTrue(text.contains("1 file"), "a single changed file must use the singular noun: \(text)")
        XCTAssertFalse(text.contains("1 files"), "a single changed file must not say '1 files': \(text)")
    }

    // MARK: 18. A rename shows both paths

    func testARenamedFileHeaderContainsBothOldAndNewPaths() {
        let file = DiffFileModel(
            path: "new/path.rs", oldPath: "old/path.rs", status: .renamed,
            additions: 0, deletions: 0, hunks: []
        )
        let doc = DiffDocument(payload: payload(files: [file]))
        let header = try! XCTUnwrap(doc.rows.first { $0.kind == .fileHeader }?.text)
        XCTAssertTrue(header.contains("old/path.rs"), "rename header must show the old path: \(header)")
        XCTAssertTrue(header.contains("new/path.rs"), "rename header must show the new path: \(header)")
    }

    // MARK: 19. `text` is the rows joined by "\n"

    func testTextEqualsRowsTextsJoinedByNewline() {
        let file = DiffFileModel(
            path: "a.rs", status: .modified, additions: 1, deletions: 1,
            hunks: [DiffHunkModel(header: "@@ h @@", oldStart: 1, newStart: 1, lines: [
                contextLine(oldN: 1, newN: 1, text: "same"),
                addedLine(newN: 2, text: "new"),
                removedLine(oldN: 2, text: "old"),
            ])]
        )
        let doc = DiffDocument(payload: payload(files: [file]))
        XCTAssertEqual(doc.text, doc.rows.map(\.text).joined(separator: "\n"))
    }
}
