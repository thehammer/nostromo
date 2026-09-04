import XCTest

// `PaneContentView.swift` is a SwiftUI view and NOT compiled into this test
// target (same situation as `CodeContentView.swift` — see
// `CodeContentViewTests.swift`), so it's read as raw source text. This is a
// fitness function, not a behavioural test: it pins the `ForEach` call sites
// in the `pr_list` renderer to an explicit `id: \.bucketScopedId`, which is
// what stops SwiftUI from reusing/recycling a PR row when that PR moves
// between buckets (the row's default `Identifiable.id` — `"\(repo)#\(number)"`
// — doesn't change on a bucket move, so a bare `ForEach(group) { ... }` /
// `ForEach(overflow) { ... }` can silently show the PR's previous bucket's
// badge under its new section header). The value-level `bucketScopedId`
// tests in `PaneContentWireTests` don't exercise the view at all, so without
// this fitness function the call sites could regress back to the bare form
// while every other test in the suite stays green.
final class PaneContentViewForEachIdentityTests: XCTestCase {

    // MARK: The bucket-grouped and overflow ForEach loops key off bucketScopedId

    func testPrListForEachLoopsAreKeyedByBucketScopedId() throws {
        let source = try Self.paneContentViewSource()

        let occurrences = Self.occurrenceCount(of: "id: \\.bucketScopedId", in: source)
        XCTAssertGreaterThanOrEqual(occurrences, 2, """
            expected at least two `id: \\.bucketScopedId` call sites in the pr_list renderer — one for \
            `ForEach(group, ...)` and one for `ForEach(overflow, ...)` — found \(occurrences). Without an \
            explicit bucket-scoped identity, a PR moving between buckets keeps its default `id` and \
            SwiftUI can recycle the old row, rendering a stale bucket badge.
            """)
    }

    func testGroupForEachNeverFallsBackToDefaultIdentity() throws {
        let source = try Self.paneContentViewSource()

        XCTAssertFalse(source.contains("ForEach(group) {"), """
            `ForEach(group) { ... }` (no explicit `id:`) reintroduces the stale-badge bug: it falls back \
            to PrListItemModel's default Identifiable id, which excludes `bucket`, so a PR that changes \
            bucket keeps its old row identity and can render the previous bucket's badge.
            """)
    }

    func testOverflowForEachNeverFallsBackToDefaultIdentity() throws {
        let source = try Self.paneContentViewSource()

        XCTAssertFalse(source.contains("ForEach(overflow) {"), """
            `ForEach(overflow) { ... }` (no explicit `id:`) reintroduces the stale-badge bug: it falls \
            back to PrListItemModel's default Identifiable id, which excludes `bucket`, so a PR that \
            changes bucket keeps its old row identity and can render the previous bucket's badge.
            """)
    }

    // MARK: - Helpers

    /// `PaneContentView.swift` is not compiled into this target, so it has to
    /// be read as text — same idiom as `CodeContentViewTests.codeContentViewSource()`.
    private static func paneContentViewSource() throws -> String {
        try String(contentsOf: sourceRoot.appendingPathComponent("UI/Views/PaneContentView.swift"), encoding: .utf8)
    }

    private static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)          // …/macOS/NostromoTests/PaneContentViewForEachIdentityTests.swift
            .deletingLastPathComponent()          // …/macOS/NostromoTests
            .deletingLastPathComponent()          // …/macOS
            .appendingPathComponent("Nostromo")
    }

    /// Number of non-overlapping occurrences of `needle` in `source`.
    private static func occurrenceCount(of needle: String, in source: String) -> Int {
        var count = 0
        var searchStart = source.startIndex
        while let range = source.range(of: needle, range: searchStart..<source.endIndex) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }
}
