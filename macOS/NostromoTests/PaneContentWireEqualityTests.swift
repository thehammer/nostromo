import XCTest
import NostromoKit

// `PaneContentWire`, `PaneTree`, `SplitDirection`, `FocusLayoutModel` are
// macOS-local types declared in Models.swift and compiled into this test
// target directly (logic test — no host app, same as PerriModelTests /
// MotherBrokerClientTests). They intentionally shadow NostromoKit's
// identically-named types within this module — see the header comment on
// Shared/NostromoKit/Sources/NostromoKit/Wire/PaneLayout.swift.
//
// `PrListItemModel` is NOT shadowed locally, so it resolves to
// `NostromoKit.PrListItemModel` here — hence the explicit `import NostromoKit`
// and the fully-qualified `NostromoKit.CiState` below (the macOS module also
// declares its own, unrelated, local `CiState` enum for `PRQueueItem`, so an
// unqualified `CiState` here would resolve to the WRONG type and fail to
// compile against `PrListItemModel.ciState`).
//
// Per-field equality coverage for `PrListItemModel` itself lives in
// Shared/NostromoKit/Tests/NostromoKitTests/PaneContentWireTests.swift, since
// that's the only module where the type is actually declared. This file only
// covers the macOS-local `PaneContentWire`'s own Equatable contract.

// MARK: - PaneContentWireEqualityTests

/// Equality-contract tests for the macOS-local `PaneContentWire` (Models.swift).
/// Mirrors the equivalent NostromoKit suite in `PaneContentWireTests.swift` —
/// the two `PaneContentWire` types are separate, deliberately-duplicated
/// copies; this file exercises only the macOS one.
final class PaneContentWireEqualityTests: XCTestCase {

    private func makeItem(
        title: String = "feat: auth"
    ) -> PrListItemModel {
        PrListItemModel(
            repo: "acme/web",
            number: 42,
            title: title,
            author: "alice",
            bucket: "requested",
            ciState: NostromoKit.CiState.success,
            newActivity: true,
            url: "https://github.com/acme/web/pull/42",
            headSha: "abc123"
        )
    }

    // MARK: - .text

    func testTextCasesWithSameStringAreEqual() {
        XCTAssertEqual(PaneContentWire.text("hello"), PaneContentWire.text("hello"))
    }

    func testTextCasesWithDifferentStringsAreNotEqual() {
        XCTAssertNotEqual(PaneContentWire.text("hello"), PaneContentWire.text("goodbye"))
    }

    // MARK: - .loading

    func testLoadingCasesAreAlwaysEqual() {
        XCTAssertEqual(PaneContentWire.loading, PaneContentWire.loading)
    }

    // MARK: - .error

    func testErrorCasesWithSameMessageAreEqual() {
        XCTAssertEqual(PaneContentWire.error("boom"), PaneContentWire.error("boom"))
    }

    func testErrorCasesWithDifferentMessagesAreNotEqual() {
        XCTAssertNotEqual(PaneContentWire.error("boom"), PaneContentWire.error("kaboom"))
    }

    // MARK: - .prList

    func testPrListCasesWithIdenticalItemArraysAreEqual() {
        let lhs = PaneContentWire.prList([makeItem()])
        let rhs = PaneContentWire.prList([makeItem()])
        XCTAssertEqual(lhs, rhs)
    }

    func testPrListCasesWithADifferingItemAreNotEqual() {
        let lhs = PaneContentWire.prList([makeItem()])
        let rhs = PaneContentWire.prList([makeItem(title: "fix: something else")])
        XCTAssertNotEqual(lhs, rhs)
    }

    // MARK: - .jsonSnapshot (conservative "always changed")

    func testJsonSnapshotCasesWithIdenticalPayloadsAreNeverEqual() {
        let payload: [String: Any] = ["x": 1]
        let lhs = PaneContentWire.jsonSnapshot(payload)
        let rhs = PaneContentWire.jsonSnapshot(payload)
        XCTAssertNotEqual(
            lhs, rhs,
            ".jsonSnapshot must compare unequal to any other value, even with an identical payload — " +
            "this is a deliberate conservative choice (report 'changed' rather than risk a false 'unchanged')"
        )
    }

    // MARK: - .unknown (conservative "always changed")

    func testUnknownCasesWithIdenticalPayloadsAreNeverEqual() {
        let payload: [String: Any] = ["future_field": "value"]
        let lhs = PaneContentWire.unknown(payload)
        let rhs = PaneContentWire.unknown(payload)
        XCTAssertNotEqual(
            lhs, rhs,
            ".unknown must compare unequal to any other value, even with an identical payload — " +
            "this is a deliberate conservative choice (report 'changed' rather than risk a false 'unchanged')"
        )
    }

    // MARK: - .code (W2 — curated-agent-views)

    private func makeCodePayload(
        path:      String = "src/main.rs",
        revision:  String = "a1b2c3d",
        firstLine: Int    = 1,
        text:      String = "let x = 1;"
    ) -> CodePayload {
        CodePayload(path: path, revision: revision, firstLine: firstLine, text: text)
    }

    func testCodeCasesWithIdenticalPayloadsAreEqual() {
        XCTAssertEqual(PaneContentWire.code(makeCodePayload()), PaneContentWire.code(makeCodePayload()))
    }

    func testCodeCasesDifferingByPathAreNotEqual() {
        XCTAssertNotEqual(
            PaneContentWire.code(makeCodePayload()),
            PaneContentWire.code(makeCodePayload(path: "src/other.rs"))
        )
    }

    func testCodeCasesDifferingByRevisionAreNotEqual() {
        XCTAssertNotEqual(
            PaneContentWire.code(makeCodePayload()),
            PaneContentWire.code(makeCodePayload(revision: "working"))
        )
    }

    func testCodeCasesDifferingByFirstLineAreNotEqual() {
        XCTAssertNotEqual(
            PaneContentWire.code(makeCodePayload()),
            PaneContentWire.code(makeCodePayload(firstLine: 42))
        )
    }

    func testCodeCasesDifferingByTextAreNotEqual() {
        XCTAssertNotEqual(
            PaneContentWire.code(makeCodePayload()),
            PaneContentWire.code(makeCodePayload(text: "let x = 2;"))
        )
    }

    // MARK: - .diff (W2 — curated-agent-views)

    private func makeDiffLine(
        kind: DiffLineModel.Kind = .context,
        oldN: Int? = 10,
        newN: Int? = 10,
        text: String = "let x = 1;"
    ) -> DiffLineModel {
        DiffLineModel(kind: kind, oldN: oldN, newN: newN, text: text)
    }

    private func makeDiffHunk(
        header:   String = "@@ -10,3 +10,5 @@ fn main() {",
        oldStart: Int = 10,
        newStart: Int = 10,
        lines:    [DiffLineModel]? = nil
    ) -> DiffHunkModel {
        DiffHunkModel(header: header, oldStart: oldStart, newStart: newStart, lines: lines ?? [makeDiffLine()])
    }

    private func makeDiffFile(
        path:      String = "src/main.rs",
        oldPath:   String? = nil,
        status:    DiffFileModel.Status = .modified,
        additions: Int = 3,
        deletions: Int = 1,
        hunks:     [DiffHunkModel]? = nil
    ) -> DiffFileModel {
        DiffFileModel(
            path: path, oldPath: oldPath, status: status,
            additions: additions, deletions: deletions, hunks: hunks ?? [makeDiffHunk()]
        )
    }

    private func makeDiffPayload(
        repo:         String = "acme/web",
        number:       Int?   = 42,
        files:        [DiffFileModel]? = nil,
        tooLarge:     Bool = false,
        changedFiles: Int  = 1
    ) -> DiffPayload {
        DiffPayload(
            repo: repo, number: number, files: files ?? [makeDiffFile()],
            tooLarge: tooLarge, changedFiles: changedFiles
        )
    }

    func testDiffCasesWithIdenticalPayloadsAreEqual() {
        XCTAssertEqual(PaneContentWire.diff(makeDiffPayload()), PaneContentWire.diff(makeDiffPayload()))
    }

    func testDiffCasesDifferingByRepoAreNotEqual() {
        XCTAssertNotEqual(
            PaneContentWire.diff(makeDiffPayload()),
            PaneContentWire.diff(makeDiffPayload(repo: "acme/other"))
        )
    }

    func testDiffCasesDifferingByNumberAreNotEqual() {
        XCTAssertNotEqual(
            PaneContentWire.diff(makeDiffPayload()),
            PaneContentWire.diff(makeDiffPayload(number: 43))
        )
    }

    func testDiffCasesDifferingByFilesAreNotEqual() {
        XCTAssertNotEqual(
            PaneContentWire.diff(makeDiffPayload()),
            PaneContentWire.diff(makeDiffPayload(files: [makeDiffFile(path: "src/other.rs")]))
        )
    }

    func testDiffCasesDifferingByTooLargeAreNotEqual() {
        XCTAssertNotEqual(
            PaneContentWire.diff(makeDiffPayload()),
            PaneContentWire.diff(makeDiffPayload(tooLarge: true))
        )
    }

    func testDiffCasesDifferingByChangedFilesAreNotEqual() {
        XCTAssertNotEqual(
            PaneContentWire.diff(makeDiffPayload()),
            PaneContentWire.diff(makeDiffPayload(changedFiles: 5))
        )
    }

    /// Proves nested `DiffFileModel`/`DiffHunkModel`/`DiffLineModel` equality
    /// actually reaches down through `.diff`'s payload — not just the
    /// top-level `DiffPayload` fields.
    func testDiffCasesWithStructurallyDifferentFilesAreNotEqual() {
        // A different hunk (header changes) inside an otherwise-identical file.
        let differentHunk = makeDiffFile(hunks: [makeDiffHunk(header: "@@ -1,1 +1,1 @@ fn other() {")])
        XCTAssertNotEqual(
            PaneContentWire.diff(makeDiffPayload(files: [makeDiffFile()])),
            PaneContentWire.diff(makeDiffPayload(files: [differentHunk])),
            "a different hunk header nested inside an identical file must be caught"
        )

        // A different line kind inside an otherwise-identical hunk.
        let differentLineKind = makeDiffFile(hunks: [makeDiffHunk(lines: [makeDiffLine(kind: .added)])])
        XCTAssertNotEqual(
            PaneContentWire.diff(makeDiffPayload(files: [makeDiffFile()])),
            PaneContentWire.diff(makeDiffPayload(files: [differentLineKind])),
            "a different line kind nested inside an identical hunk must be caught"
        )

        // A different oldPath (rename provenance) on an otherwise-identical file.
        let differentOldPath = makeDiffFile(oldPath: "src/renamed_from.rs", status: .renamed)
        XCTAssertNotEqual(
            PaneContentWire.diff(makeDiffPayload(files: [makeDiffFile(status: .renamed)])),
            PaneContentWire.diff(makeDiffPayload(files: [differentOldPath])),
            "a different oldPath nested inside an identical file must be caught"
        )
    }

    // MARK: - Cross-case inequality

    func testDifferentCasesAreNeverEqual() {
        XCTAssertNotEqual(PaneContentWire.text("hello"), PaneContentWire.loading)
        XCTAssertNotEqual(PaneContentWire.error("boom"), PaneContentWire.text("boom"))
        XCTAssertNotEqual(PaneContentWire.prList([makeItem()]), PaneContentWire.loading)
    }

    func testCodeCaseNeverEqualsDiffTextOrLoading() {
        let code = PaneContentWire.code(makeCodePayload())
        XCTAssertNotEqual(code, PaneContentWire.diff(makeDiffPayload()))
        XCTAssertNotEqual(code, PaneContentWire.text("let x = 1;"))
        XCTAssertNotEqual(code, PaneContentWire.loading)
    }
}
