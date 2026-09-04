import XCTest

/// Fitness functions, not behavioural tests — same spirit as
/// `PerFocusEvictionWiringTests` / `ActivityTickerWiringTests`. The logic
/// under test here lives in `AppStore.swift`'s `pushDetailToDiffPane`, which
/// is not compiled into the `NostromoTests` logic-test target (confirmed via
/// `Nostromo.xcodeproj/project.pbxproj`'s `TestSources` build phase — that
/// file appears only under the app target's `Sources`). So the only way to
/// enforce this fix's wiring is to read the file as text.
///
/// Every assertion below is a textual heuristic, not a control-flow proof —
/// a determined refactor could rearrange the source enough to dodge one of
/// these checks while preserving (or breaking) the real behavior. They exist
/// to catch the concrete, plausible ways this fix regresses.
///
/// RED phase: `pushDetailToDiffPane` still has the OLD code (a hard-coded
/// `"diff"` string literal, no reference to `DiffPaneSummaryPolicy` at all)
/// at the time these tests are written, so BOTH assertions below are expected
/// to FAIL until the implementer rewrites the call site to consult the new
/// policy — that is the correct RED-phase result, not a bug in these tests.
final class DiffPaneSummaryWiringTests: XCTestCase {

    // MARK: - pushDetailToDiffPane consults DiffPaneSummaryPolicy

    func testPushDetailToDiffPaneReferencesDiffPaneSummaryPolicy() throws {
        let source = try Self.appStoreSource()
        let body = try Self.isolatedFunctionBody(named: "func pushDetailToDiffPane", in: source, sourceFile: "AppStore.swift")
        XCTAssertTrue(body.contains("DiffPaneSummaryPolicy"), """
            pushDetailToDiffPane must reference DiffPaneSummaryPolicy — without the call site \
            actually consulting the policy's shouldWriteSummary(tree:existing:) decision, having \
            DiffPaneSummaryPolicy exist as an unused type does nothing to stop the phantom-diff-pane \
            write into perri-curated's nonexistent "diff" pane.
            """)
    }

    // MARK: - pushDetailToDiffPane has no second hard-coded "diff" literal

    func testPushDetailToDiffPaneHasNoBareDiffStringLiteral() throws {
        let source = try Self.appStoreSource()
        let body = try Self.isolatedFunctionBody(named: "func pushDetailToDiffPane", in: source, sourceFile: "AppStore.swift")
        XCTAssertFalse(body.contains("\"diff\""), """
            pushDetailToDiffPane must not contain a bare "diff" string literal — the pane id must \
            be sourced from DiffPaneSummaryPolicy.paneId, the single source of truth, not from a \
            second hard-coded literal living beside the policy that could drift out of sync with it.
            """)
    }

    // MARK: - Source helpers
    //
    // Copied from PerFocusEvictionWiringTests' sourceFile(_:) /
    // isolatedFunctionBody(named:in:sourceFile:) pattern rather than
    // reinvented — see that file for the fuller rationale comment.

    private static func appStoreSource() throws -> String { try sourceFile("Nostromo/Data/AppStore.swift") }

    private static func sourceFile(_ relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)     // …/macOS/NostromoTests/DiffPaneSummaryWiringTests.swift
            .deletingLastPathComponent()                // …/macOS/NostromoTests
            .deletingLastPathComponent()                // …/macOS
            .appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Isolates a function's body by counting braces from its first `{` after
    /// `signature` to the matching close. A textual heuristic, not a real
    /// parser — sufficient to check "does this function's body mention X",
    /// not to prove anything about control flow or scoping precision.
    private static func isolatedFunctionBody(named signature: String, in source: String, sourceFile: String,
                                             file: StaticString = #filePath, line: UInt = #line) throws -> String {
        guard let sigRange = source.range(of: signature) else {
            XCTFail("\(signature) not found in \(sourceFile) yet", file: file, line: line)
            return ""
        }
        guard let openBrace = source[sigRange.upperBound...].firstIndex(of: "{") else {
            XCTFail("\(signature) has no body in \(sourceFile)", file: file, line: line)
            return ""
        }
        var depth = 0
        var idx = openBrace
        while idx < source.endIndex {
            let ch = source[idx]
            if ch == "{" { depth += 1 }
            if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return String(source[source.index(after: openBrace)..<idx])
                }
            }
            idx = source.index(after: idx)
        }
        XCTFail("could not find a matching closing brace for \(signature) in \(sourceFile)", file: file, line: line)
        return ""
    }
}
