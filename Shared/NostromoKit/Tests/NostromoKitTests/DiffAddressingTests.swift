import XCTest
@testable import NostromoKit

// L1 coverage for `DiffDocument.resolve(anchor:)` / `resolve(emphasis:)` and
// the three-state `AnchorResolution`/`EmphasisResolution` types applied to a
// diff (ios-curated-view-parity W8, D3/D4). Mirrors `AnchorResolutionTests`'
// structure and its substring-assertion style — reasons are asserted via
// `.contains(...)`, never exact string equality, since the reason text is
// operator-facing prose the view renders (D7 in W7's memo), not a wire
// contract.
//
// The `tooLarge` cases are the ones an independent implementation gets
// backwards: a gated diff has no rows to resolve against at all, so even an
// anchor kind this surface otherwise can't use, or a path naming no file,
// must still report the gate — not its own, more specific-sounding, reason.

final class DiffAddressingTests: XCTestCase {

    // MARK: - Fixture builders

    private func addedLine(_ newN: Int) -> DiffLineModel {
        DiffLineModel(kind: .added, oldN: nil, newN: newN, text: "line \(newN)")
    }

    private func removedLine(_ oldN: Int) -> DiffLineModel {
        DiffLineModel(kind: .removed, oldN: oldN, newN: nil, text: "line \(oldN)")
    }

    /// A file whose single hunk adds every line number in `range` — the
    /// simplest fixture shape for tests about which rows a line/range
    /// resolves to, independent of any particular file's real content.
    private func fileAddingLines(_ range: ClosedRange<Int>, path: String) -> DiffFileModel {
        DiffFileModel(
            path: path, status: .modified, additions: range.count, deletions: 0,
            hunks: [DiffHunkModel(
                header: "@@ h @@", oldStart: range.lowerBound, newStart: range.lowerBound,
                lines: range.map(addedLine)
            )]
        )
    }

    private func document(files: [DiffFileModel], tooLarge: Bool = false, changedFiles: Int = 0) -> DiffDocument {
        DiffDocument(payload: DiffPayload(
            repo: "acme/web", number: 7, files: files, tooLarge: tooLarge, changedFiles: changedFiles
        ))
    }

    // MARK: Anchor — absent

    func testNoAnchorIsNotRequested() {
        let resolution = document(files: [fileAddingLines(1...5, path: "a.rs")]).resolve(anchor: nil)
        XCTAssertEqual(resolution, .notRequested)
        XCTAssertNotEqual(resolution, .unresolved(reason: ""))
        XCTAssertNotEqual(resolution, .resolved(target: 0))
    }

    // MARK: tooLarge gates every anchor kind, before any anchor-specific rule

    func testTooLargeDiffAnchorIsAlwaysUnresolvedNamingTheGateAndTheFileCountRegardlessOfAnchorKind() {
        let document = self.document(files: [], tooLarge: true, changedFiles: 12)
        let anchors: [Anchor] = [
            .line(path: "a.rs", line: 5),
            .line(path: "nonexistent.rs", line: 5),
            .comment(id: "abc"),
            .section(name: "Intro"),
            .queueRow(repo: "acme/web", number: 1),
        ]
        for anchor in anchors {
            guard case .unresolved(let reason) = document.resolve(anchor: anchor) else {
                XCTFail("expected .unresolved for \(anchor)")
                continue
            }
            XCTAssertTrue(
                reason.localizedCaseInsensitiveContains("too large"),
                "a gated diff has no rows to resolve against — the reason must say so even for \(anchor): \(reason)"
            )
            XCTAssertTrue(reason.contains("12"), "reason must name the changed-file count: \(reason)")
        }
    }

    func testTooLargeDiffEmphasisIsAlwaysMatchedNothingNamingTheGateAndTheFileCountRegardlessOfEmphasisKind() {
        let document = self.document(files: [], tooLarge: true, changedFiles: 12)
        let emphasesToTry: [[Emphasis]] = [
            [.lineRange(path: "a.rs", start: 1, end: 5)],
            [.lineRange(path: "nonexistent.rs", start: 1, end: 5)],
            [.comment(id: "abc")],
            [.section(name: "Intro")],
            [.textRange(start: 0, end: 10)],
            [.queueRow(repo: "acme/web", number: 1)],
        ]
        for emphases in emphasesToTry {
            guard case .matchedNothing(let reason) = document.resolve(emphasis: emphases) else {
                XCTFail("expected .matchedNothing for \(emphases)")
                continue
            }
            XCTAssertTrue(
                reason.localizedCaseInsensitiveContains("too large"),
                "a gated diff has no rows to resolve against — the reason must say so even for \(emphases): \(reason)"
            )
            XCTAssertTrue(reason.contains("12"), "reason must name the changed-file count: \(reason)")
        }
    }

    // MARK: Anchor — a line within the diff

    func testLineAnchorForAnAddedLineOnTheNewSideResolvesToItsRowNotARemovedRow() {
        let document = self.document(files: [fileAddingLines(1...10, path: "a.rs")])
        guard case .resolved(let target) = document.resolve(anchor: .line(path: "a.rs", line: 5)) else {
            return XCTFail("expected .resolved")
        }
        XCTAssertEqual(document.rows[target].path, "a.rs")
        XCTAssertNotEqual(document.rows[target].kind, .removed)
    }

    func testLineAnchorForAPureDeletionResolvesToTheRemovalRow() {
        let file = DiffFileModel(
            path: "a.rs", status: .modified, additions: 0, deletions: 1,
            hunks: [DiffHunkModel(header: "@@ h @@", oldStart: 7, newStart: 7, lines: [removedLine(7)])]
        )
        let document = self.document(files: [file])
        guard case .resolved(let target) = document.resolve(anchor: .line(path: "a.rs", line: 7)) else {
            return XCTFail("expected .resolved")
        }
        XCTAssertEqual(document.rows[target].kind, .removed)
        XCTAssertEqual(document.rows[target].oldN, 7)
    }

    func testLineAnchorPresentAsBothARemovalAndAnAdditionResolvesToTheAddedRow() {
        let file = DiffFileModel(
            path: "a.rs", status: .modified, additions: 1, deletions: 1,
            hunks: [DiffHunkModel(header: "@@ h @@", oldStart: 5, newStart: 5, lines: [
                removedLine(5), addedLine(5),
            ])]
        )
        let document = self.document(files: [file])
        guard case .resolved(let target) = document.resolve(anchor: .line(path: "a.rs", line: 5)) else {
            return XCTFail("expected .resolved")
        }
        XCTAssertEqual(document.rows[target].kind, .added, "new-side numbering wins when a line is both a removal and an addition")
    }

    func testLineAnchorWithNoPathSearchesEveryFileAndSelectsWhicheverActuallyHasTheLine() {
        let document = self.document(files: [
            fileAddingLines(1...5, path: "a.rs"),
            fileAddingLines(90...100, path: "b.rs"),
            fileAddingLines(200...210, path: "c.rs"),
        ])
        guard case .resolved(let target) = document.resolve(anchor: .line(path: nil, line: 95)) else {
            return XCTFail("expected .resolved")
        }
        XCTAssertEqual(document.rows[target].path, "b.rs", "a path-less anchor must find whichever file actually has the line")
    }

    // MARK: Anchor — a missing path vs. a missing line are two different facts

    func testLineAnchorForAPathAbsentFromTheDiffIsUnresolvedNamingThePathAndTheFileCount() {
        let document = self.document(files: [
            fileAddingLines(1...5, path: "a.rs"),
            fileAddingLines(1...5, path: "b.rs"),
            fileAddingLines(1...5, path: "c.rs"),
        ])
        guard case .unresolved(let reason) = document.resolve(anchor: .line(path: "missing.rs", line: 1)) else {
            return XCTFail("expected .unresolved")
        }
        XCTAssertTrue(reason.contains("missing.rs"), "reason must name the requested path: \(reason)")
        XCTAssertTrue(reason.contains("3"), "reason must name how many files this diff actually changes: \(reason)")
        XCTAssertFalse(reason.contains("9999"), "this must not be the 'line not found' reason's text")
    }

    func testLineAnchorForALineAbsentFromAnExistingFileIsUnresolvedDistinctlyFromTheMissingPathCase() {
        let document = self.document(files: [
            fileAddingLines(1...5, path: "a.rs"),
            fileAddingLines(1...5, path: "b.rs"),
            fileAddingLines(1...5, path: "c.rs"),
        ])
        guard case .unresolved(let lineReason) = document.resolve(anchor: .line(path: "a.rs", line: 9999)) else {
            return XCTFail("expected .unresolved")
        }
        XCTAssertTrue(lineReason.contains("9999"), "reason must name the requested line: \(lineReason)")
        XCTAssertFalse(lineReason.contains("missing.rs"), "this must not be the missing-path reason's text")

        guard case .unresolved(let pathReason) = document.resolve(anchor: .line(path: "missing.rs", line: 1)) else {
            return XCTFail("expected .unresolved")
        }
        XCTAssertNotEqual(
            lineReason, pathReason,
            "'this file isn't in the diff' and 'this line isn't in the diff' are different facts and must be different messages"
        )
    }

    func testLineAnchorWithNoPathForALineAbsentFromEveryFileIsUnresolvedNamingTheLine() {
        let document = self.document(files: [
            fileAddingLines(1...5, path: "a.rs"),
            fileAddingLines(1...5, path: "b.rs"),
        ])
        guard case .unresolved(let reason) = document.resolve(anchor: .line(path: nil, line: 9999)) else {
            return XCTFail("expected .unresolved")
        }
        XCTAssertTrue(reason.contains("9999"))
    }

    // MARK: Anchor — a kind this surface cannot use

    func testCommentAnchorIsUnresolvedNamingTheKind() {
        let document = self.document(files: [fileAddingLines(1...5, path: "a.rs")])
        guard case .unresolved(let reason) = document.resolve(anchor: .comment(id: "abc")) else {
            return XCTFail("expected .unresolved")
        }
        XCTAssertTrue(reason.lowercased().contains("comment"), "reason must name the anchor kind: \(reason)")
    }

    func testSectionAnchorIsUnresolvedNamingTheKind() {
        let document = self.document(files: [fileAddingLines(1...5, path: "a.rs")])
        guard case .unresolved(let reason) = document.resolve(anchor: .section(name: "Intro")) else {
            return XCTFail("expected .unresolved")
        }
        XCTAssertTrue(reason.lowercased().contains("section"), "reason must name the anchor kind: \(reason)")
    }

    func testQueueRowAnchorIsUnresolvedNamingTheKind() {
        let document = self.document(files: [fileAddingLines(1...5, path: "a.rs")])
        guard case .unresolved(let reason) = document.resolve(anchor: .queueRow(repo: "acme/web", number: 1)) else {
            return XCTFail("expected .unresolved")
        }
        XCTAssertTrue(reason.lowercased().contains("queue"), "reason must name the anchor kind: \(reason)")
    }

    // MARK: Emphasis — absent

    func testNoEmphasisIsNone() {
        XCTAssertEqual(document(files: [fileAddingLines(1...5, path: "a.rs")]).resolve(emphasis: []), .none)
    }

    // MARK: Emphasis — fully in range

    func testFullyInRangeLineRangeResolvesToEveryMatchingRowSortedAscending() {
        let document = self.document(files: [fileAddingLines(10...15, path: "a.rs")])
        guard case .rows(let rows) = document.resolve(emphasis: [.lineRange(path: "a.rs", start: 10, end: 15)]) else {
            return XCTFail("expected .rows")
        }
        XCTAssertEqual(rows, rows.sorted(), "rows must come back in ascending order")
        XCTAssertEqual(rows.count, 6, "all six lines in 10...15 exist in this diff")
        for r in rows { XCTAssertEqual(document.rows[r].path, "a.rs") }
    }

    // MARK: Emphasis — partially in range

    func testPartiallyInRangeLineRangeResolvesOnlyTheIntersectingRows() {
        let document = self.document(files: [fileAddingLines(10...12, path: "a.rs")])
        guard case .rows(let rows) = document.resolve(emphasis: [.lineRange(path: "a.rs", start: 8, end: 20)]) else {
            return XCTFail("expected .rows")
        }
        XCTAssertEqual(rows.count, 3, "only lines 10...12 actually exist in this diff")
    }

    // MARK: Emphasis — fully out of range

    func testFullyOutOfRangeLineRangeIsMatchedNothingWithAReasonNamingTheBoundsNotAClampedSpan() {
        let document = self.document(files: [fileAddingLines(1...5, path: "a.rs")])
        let resolution = document.resolve(emphasis: [.lineRange(path: "a.rs", start: 1000, end: 1010)])
        guard case .matchedNothing(let reason) = resolution else {
            return XCTFail("expected .matchedNothing, got \(resolution)")
        }
        XCTAssertTrue(reason.contains("1000") || reason.contains("1010"), "reason must name the requested bounds: \(reason)")
        // The regression this guards: "matching nothing" rendered as "matching
        // everything" by silently falling back to an empty-but-truthy `.rows`.
        XCTAssertNotEqual(resolution, .rows([]))
    }

    // MARK: Emphasis — inverted range

    func testInvertedRangeIsMatchedNothing() {
        let document = self.document(files: [fileAddingLines(1...5, path: "a.rs")])
        guard case .matchedNothing = document.resolve(emphasis: [.lineRange(path: "a.rs", start: 8, end: 3)]) else {
            return XCTFail("expected .matchedNothing for an inverted range")
        }
    }

    // MARK: Emphasis — a missing path

    func testLineRangeForAPathAbsentFromTheDiffIsMatchedNothingNamingThePath() {
        let document = self.document(files: [fileAddingLines(1...5, path: "a.rs")])
        guard case .matchedNothing(let reason) = document.resolve(emphasis: [.lineRange(path: "missing.rs", start: 1, end: 5)]) else {
            return XCTFail("expected .matchedNothing")
        }
        XCTAssertTrue(reason.contains("missing.rs"), "reason must name the requested path: \(reason)")
    }

    // MARK: Emphasis — kinds this surface cannot use

    func testCommentEmphasisIsMatchedNothingNamingTheKind() {
        let document = self.document(files: [fileAddingLines(1...5, path: "a.rs")])
        guard case .matchedNothing(let reason) = document.resolve(emphasis: [.comment(id: "abc")]) else {
            return XCTFail("expected .matchedNothing")
        }
        XCTAssertTrue(reason.lowercased().contains("comment"), "reason must name the emphasis kind: \(reason)")
    }

    func testSectionEmphasisIsMatchedNothingNamingTheKind() {
        let document = self.document(files: [fileAddingLines(1...5, path: "a.rs")])
        guard case .matchedNothing(let reason) = document.resolve(emphasis: [.section(name: "Intro")]) else {
            return XCTFail("expected .matchedNothing")
        }
        XCTAssertTrue(reason.lowercased().contains("section"), "reason must name the emphasis kind: \(reason)")
    }

    func testTextRangeEmphasisIsMatchedNothingNamingItHasNoCharacterOffsetRanges() {
        let document = self.document(files: [fileAddingLines(1...5, path: "a.rs")])
        guard case .matchedNothing(let reason) = document.resolve(emphasis: [.textRange(start: 0, end: 10)]) else {
            return XCTFail("expected .matchedNothing")
        }
        XCTAssertTrue(reason.lowercased().contains("character"), "a diff view has no character-offset ranges: \(reason)")
    }

    func testQueueRowEmphasisIsMatchedNothingNamingTheKind() {
        let document = self.document(files: [fileAddingLines(1...5, path: "a.rs")])
        guard case .matchedNothing(let reason) = document.resolve(emphasis: [.queueRow(repo: "acme/web", number: 1)]) else {
            return XCTFail("expected .matchedNothing")
        }
        XCTAssertTrue(reason.lowercased().contains("queue"), "reason must name the emphasis kind: \(reason)")
    }

    // MARK: Emphasis — union across multiple entries, one of which fails

    func testMultipleEmphasisEntriesUnionWithoutDuplicatingRowsEvenWhenOneEntryFailsToResolve() {
        let document = self.document(files: [fileAddingLines(1...20, path: "a.rs")])
        let resolution = document.resolve(emphasis: [
            .lineRange(path: "a.rs", start: 1, end: 3),
            .lineRange(path: "a.rs", start: 2, end: 5),
            .comment(id: "abc"), // this entry cannot resolve at all
        ])
        guard case .rows(let rows) = resolution else {
            return XCTFail("expected .rows — one failing entry must not blank a result another entry produced, got \(resolution)")
        }
        XCTAssertEqual(rows, rows.sorted())
        XCTAssertEqual(Set(rows).count, rows.count, "overlapping ranges must not duplicate a row")
        XCTAssertEqual(rows.count, 5, "the union of 1...3 and 2...5 is lines 1...5 — five rows")
    }
}
