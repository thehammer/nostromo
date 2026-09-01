import XCTest

// `DynamicFocusView.swift` is AppKit and NOT compiled into the host-less
// `NostromoTests` bundle (same reason `CodeContentViewTests.swift` treats it
// as text — see that file's header comment). These are fitness functions,
// not behavioural tests: they describe the target state of code that
// doesn't exist yet. Cody is about to rewrite large parts of
// `DynamicFocusView.swift` so that `renderedTree` can never advance past a
// repair step that actually failed (the "silent divergence" bug this branch
// fixes) — these tests are expected to FAIL against the current file; that's
// the RED phase.

/// Fitness functions pinning the shape of the reconciliation fix in
/// `DynamicFocusView.swift` (fix/detail-region-content-not-rendering).
final class DynamicFocusViewWiringTests: XCTestCase {

    // MARK: a. renderedTree is assigned in exactly one place, inside `reconcile`

    func testRenderedTreeIsAssignedInExactlyOnePlaceInsideAFunctionNamedReconcile() throws {
        let source = try Self.dynamicFocusViewSource()

        let assignmentLines = Self.lines(containing: "renderedTree = ", in: source)
        XCTAssertEqual(assignmentLines.count, 1, """
            RC2: renderedTree must be assigned in exactly one place in the whole file. Before the fix, several \
            branches of handleLayoutUpdate (and renderLayout) each advanced renderedTree independently — which is \
            exactly the bug: an incremental repair path (applyActiveTabOnly/applyTabMembership) can fail partway \
            through and the bookkeeping still advances as if it fully succeeded, so nothing ever detects the \
            divergence. Found \(assignmentLines.count) assignment(s):
            \(assignmentLines.joined(separator: "\n"))
            """)

        guard let onlyAssignmentLine = assignmentLines.first,
              let occurrence = source.range(of: onlyAssignmentLine)
        else { return }

        // Nearest preceding `func` — same "scope since the last `func`
        // keyword" approximation CodeContentViewTests.occurrencesOutsideScrollToBranch
        // uses: robust to reformatting, only fooled by another `func`
        // inserted in between, which would be a stranger change than this
        // test is trying to guard against.
        guard let precedingFunc = source.range(
            of: "func ", options: .backwards, range: source.startIndex..<occurrence.lowerBound
        ) else {
            XCTFail("RC2: no enclosing `func` found before the sole renderedTree assignment")
            return
        }
        let funcLine = source[source.lineRange(for: precedingFunc)]
        XCTAssertTrue(funcLine.contains("reconcile"), """
            RC2: the sole renderedTree assignment must live inside a function whose signature contains \
            "reconcile" — a single, named choke point for advancing the rendered-state bookkeeping is what makes \
            "did the repair actually succeed?" checkable in one place instead of scattered across every branch. \
            Enclosing func line found: \(funcLine)
            """)
    }

    // MARK: b. No bare `continue`/`return` in the guard-driven repair paths

    func testGuardDrivenRepairFunctionsHaveNoBareContinueOrReturn() throws {
        let source = try Self.dynamicFocusViewSource()
        let names = ["applyActiveTabOnly", "applyTabMembership", "replaceInPlace", "updateContent"]

        for name in names {
            let body = try Self.functionBody(named: name, in: source)
            let violations = Self.bareStatementLines(in: body)
            XCTAssertTrue(violations.isEmpty, """
                \(name) must not contain a bare `continue` or bare `return` — every failure path in it must now \
                propagate a signal (e.g. return a Bool the caller checks, or otherwise be caught) rather than \
                silently doing nothing, which is exactly how a failed repair step used to go undetected. \
                Found \(violations.count) bare occurrence(s) in \(name)'s body.
                """)
        }
    }

    // MARK: c. PaneContentNSView.update clears content in every hidden branch

    func testEveryIsHiddenTrueBranchInPaneContentNSViewUpdateAlsoClearsContent() throws {
        let source = try Self.dynamicFocusViewSource()
        let body = try Self.functionBody(named: "update", in: source, signaturePrefix: "func update(content:")
        let lines = Self.linesArray(body)

        for name in ["codeView", "conversationView", "ticketView"] {
            guard let idx = lines.firstIndex(where: { $0.contains("\(name).isHidden = true") }) else {
                XCTFail("\(name).isHidden = true not found in PaneContentNSView.update — did the branch move or rename?")
                continue
            }
            let lo = max(0, idx - 3)
            let hi = min(lines.count - 1, idx + 3)
            let vicinity = lines[lo...hi].joined(separator: "\n")
            XCTAssertTrue(vicinity.contains("\(name).clearContent()"), """
                \(name).isHidden = true must be accompanied by a \(name).clearContent() call in the same branch — \
                otherwise a pane that flips away from this content kind leaves stale content sitting behind it, \
                invisible until the pane flips back to that kind and the stale content flashes into view. \
                Vicinity checked:
                \(vicinity)
                """)
        }
    }

    // MARK: d. No bare NSSplitView() construction

    func testDynamicFocusViewConstructsNoBareNSSplitView() throws {
        let source = try Self.dynamicFocusViewSource()
        XCTAssertFalse(source.contains("NSSplitView()"), """
            DynamicFocusView must never construct a bare NSSplitView() — only RatioSplitView() may be \
            instantiated, so a future split node can't reintroduce the never-applied-ratios bug. (NSSplitView as \
            a type annotation/cast, e.g. `as? NSSplitView`, is fine — only the bare constructor call is forbidden.)
            """)
    }

    // MARK: e. applyRatios is never invoked from inside DispatchQueue.main.async

    func testApplyRatiosIsNeverInvokedInsideADispatchMainAsyncBlock() throws {
        let source = try Self.dynamicFocusViewSource()
        let blocks = Self.balancedBraceBlocks(startingAt: "DispatchQueue.main.async {", in: source)
        for block in blocks {
            XCTAssertFalse(block.contains("applyRatios"), """
                applyRatios must not be invoked from inside a DispatchQueue.main.async block — deferring to a \
                later, unconditional run-loop turn is exactly the layout-timing bug this branch fixes: the split \
                can still report zero size when that block finally runs, and a fire-and-forget async dispatch has \
                no way to notice that and retry. Offending block:
                \(block)
                """)
        }
    }

    // MARK: Bonus. replaceInPlace's result must gate the following registerTabRegion call

    func testReplaceInPlaceResultGatesTheFollowingRegisterTabRegionCall() throws {
        let source = try Self.dynamicFocusViewSource()
        let body = try Self.functionBody(named: "applyTabMembership", in: source)

        // Textual heuristic, not a control-flow proof (same honest caveat
        // CodeContentViewTests' own docstring uses): this only catches the
        // specific "two statements back to back with nothing gating the
        // second on the first's result" shape. It cannot verify that
        // whatever gating exists is correct, only that the old unconditional
        // shape is gone.
        let oldUngatedPattern = "replaceInPlace(oldRegion, with: newRegion)\n\n            registerTabRegion(newRegion"
        XCTAssertFalse(body.contains(oldUngatedPattern), """
            applyTabMembership must not call registerTabRegion(newRegion...) unconditionally immediately after \
            replaceInPlace(oldRegion, with: newRegion) now that replaceInPlace returns Bool — the call must be \
            gated (e.g. `guard replaceInPlace(...) else { ... }` or an `if` on its result). Otherwise a failed \
            in-place swap still registers tab-region bookkeeping for a view that was never actually inserted into \
            the hierarchy — the exact "bookkeeping advances as if the repair succeeded" bug.
            """)
    }

    // MARK: - Helpers

    private static func dynamicFocusViewSource() throws -> String {
        try String(contentsOf: sourceRoot.appendingPathComponent("UI/Views/DynamicFocusView.swift"), encoding: .utf8)
    }

    private static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)          // …/macOS/NostromoTests/DynamicFocusViewWiringTests.swift
            .deletingLastPathComponent()          // …/macOS/NostromoTests
            .deletingLastPathComponent()          // …/macOS
            .appendingPathComponent("Nostromo")
    }

    /// Every line containing `needle`, in order.
    private static func lines(containing needle: String, in source: String) -> [String] {
        source.components(separatedBy: "\n").filter { $0.contains(needle) }
    }

    private static func linesArray(_ text: String) -> [String] {
        text.components(separatedBy: "\n")
    }

    /// Every line in `body` that contains a bare (no-argument) `continue` or
    /// `return` statement — whether it sits alone on its own line
    /// (`            continue`) or inline inside a single-line guard
    /// (`else { continue }`). Splitting each line on `{`/`}`/`;` first turns
    /// both shapes into the same "is one of this line's statements exactly
    /// `continue`/`return`?" question, so this isn't fooled by a same-line
    /// `guard ... else { return }` the way a plain whole-line-trim check
    /// would be — and it still lets `return someValue` or `return isValid`
    /// through unflagged, since neither trims down to exactly `continue` or
    /// `return`.
    private static func bareStatementLines(in body: String) -> [String] {
        linesArray(body).filter { line in
            let statements = line
                .components(separatedBy: CharacterSet(charactersIn: "{};"))
                .map { $0.trimmingCharacters(in: .whitespaces) }
            return statements.contains("continue") || statements.contains("return")
        }
    }

    /// Every balanced `{ ... }` block starting at `marker` (which must itself
    /// end in `{`), matching brace depth so a nested block doesn't truncate
    /// the match. Mirrors `CodeContentViewTests.balancedCalls`, but for
    /// braces instead of parens.
    private static func balancedBraceBlocks(startingAt marker: String, in source: String) -> [String] {
        var blocks: [String] = []
        var searchStart = source.startIndex
        while let markerRange = source.range(of: marker, range: searchStart..<source.endIndex) {
            var depth = 1   // `marker` already includes the opening "{"
            var idx = markerRange.upperBound
            while idx < source.endIndex, depth > 0 {
                if source[idx] == "{" { depth += 1 }
                if source[idx] == "}" { depth -= 1 }
                idx = source.index(after: idx)
            }
            blocks.append(String(source[markerRange.lowerBound..<idx]))
            searchStart = idx
        }
        return blocks
    }

    private struct SourceScanError: Error, CustomStringConvertible {
        let description: String
    }

    /// The body (from the opening `{` to its matching closing `}`) of the
    /// function whose signature starts with `signaturePrefix` (defaulting to
    /// `func <name>(`) — brace-depth matched so a nested closure inside the
    /// function doesn't truncate the extraction.
    private static func functionBody(
        named name: String, in source: String, signaturePrefix: String? = nil
    ) throws -> String {
        let marker = signaturePrefix ?? "func \(name)("
        guard let sigRange = source.range(of: marker) else {
            throw SourceScanError(description: "'\(marker)' not found in DynamicFocusView.swift — did it move or rename?")
        }
        guard let braceStart = source.range(of: "{", range: sigRange.upperBound..<source.endIndex) else {
            throw SourceScanError(description: "no opening brace found after '\(marker)'")
        }
        var depth = 1
        var idx = braceStart.upperBound
        while idx < source.endIndex, depth > 0 {
            if source[idx] == "{" { depth += 1 }
            if source[idx] == "}" { depth -= 1 }
            idx = source.index(after: idx)
        }
        return String(source[braceStart.lowerBound..<idx])
    }
}
