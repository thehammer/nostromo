import XCTest

// `CodeContentView.swift` and `DynamicFocusView.swift` are NOT compiled into
// this target — `CodeContentView` is real AppKit chrome (an `NSScrollView` +
// `NSTextView` pair that is built once and never torn down), and the
// host-less `NostromoTests` bundle has no window server to lay either of
// those out in. These are fitness functions, not behavioural tests: the same
// idiom as `ImageDecodePolicyTests` and `TurnInteractionWiringTests` — read
// the source as text and enforce the wiring rules that can't be observed any
// other way in this target.

/// Fitness functions for `CodeContentView`'s obedience to `ScrollDecision`,
/// `DynamicFocusView`'s forwarding of `PaneAddress` into it, and its "never
/// tear down the scroll/text view" discipline (W2 — curated-agent-views).
final class CodeContentViewTests: XCTestCase {

    // MARK: 24. CodeContentView only scrolls via ScrollDecision.decide

    func testCodeContentViewConsultsScrollDecisionAndOnlyScrollsFromTheScrollToBranch() throws {
        let source = try Self.codeContentViewSource()
        XCTAssertTrue(source.contains("ScrollDecision.decide("),
                      "CodeContentView must ask ScrollDecision.decide( whether to move the viewport, " +
                      "rather than deciding for itself")

        let violations = Self.occurrencesOutsideScrollToBranch(of: "scrollRowToCentre(", in: source)
        XCTAssertTrue(violations.isEmpty, """
            scrollRowToCentre( is called somewhere other than its own definition or a `case .scrollTo` \
            branch — that reintroduces exactly the "re-emphasis yanks the viewport" bug ScrollDecision \
            exists to prevent:
            \(violations.joined(separator: "\n"))
            """)
    }

    // MARK: 25. DynamicFocusView forwards the address into the code view

    func testPaneContentNSViewForwardsAddressIntoTheCodeView() throws {
        let source = try Self.dynamicFocusViewSource()
        let calls = Self.balancedCalls(startingAt: "codeView.update(content:", in: source)
        XCTAssertFalse(calls.isEmpty, "codeView.update(content: call site not found — did it move or rename?")
        for call in calls {
            XCTAssertTrue(call.contains("address:"), """
                codeView.update(content:) must forward the pane's address, or an anchor/emphasis push \
                never reaches the code renderer:
                \(call)
                """)
        }
    }

    // MARK: 26. CodeContentView never tears down its scroll/text view

    func testCodeContentViewNeverTearsDownItsScrollOrTextViewOnUpdate() throws {
        let source = try Self.codeContentViewSource()
        XCTAssertFalse(source.contains("removeFromSuperview()"), """
            CodeContentView must be built once and never torn down (D7) — a removeFromSuperview() call \
            anywhere in this file would tear down persistent AppKit chrome the same way the pre-fix bug did.
            """)

        let assignments = Self.lines(containing: "scrollView.documentView", in: source)
        XCTAssertEqual(assignments.count, 1, """
            scrollView.documentView must be assigned exactly once, in init — extra assignments found:
            \(assignments.joined(separator: "\n"))
            """)
        if let onlyAssignment = assignments.first {
            XCTAssertTrue(onlyAssignment.contains("scrollView.documentView") && onlyAssignment.contains("textView"),
                          "the single documentView assignment must wire scrollView to textView: \(onlyAssignment)")
        }
        // Confirm that lone assignment sits inside init, not some later
        // update path — `init` is the only place before the first `// MARK:`
        // section that isn't itself titled "Init".
        let initRange = try XCTUnwrap(source.range(of: "override init(frame frameRect: NSRect) {"))
        let nextMarkAfterInit = source.range(of: "// MARK: - Rendering", range: initRange.upperBound..<source.endIndex)
        let assignmentRange = try XCTUnwrap(source.range(of: "scrollView.documentView"))
        XCTAssertTrue(assignmentRange.lowerBound > initRange.lowerBound, "the assignment must be inside init")
        if let nextMarkAfterInit {
            XCTAssertTrue(assignmentRange.upperBound < nextMarkAfterInit.lowerBound,
                          "the assignment must be inside init, before the next MARK section")
        }
    }

    // MARK: 29. drawHashMarksAndLabels feeds CodePaneRenderAudit

    func testDrawHashMarksAndLabelsFeedsCodePaneRenderAudit() throws {
        let source = try Self.codeContentViewSource()
        XCTAssertTrue(source.contains("CodePaneRenderAudit.Measurements("), """
            drawHashMarksAndLabels must construct a CodePaneRenderAudit.Measurements from the pass it \
            just drew — removing this call would silently disable the tripwire this diagnostics job \
            exists to add, leaving a rare blank-body-with-correct-gutter render bug undetectable again.
            """)
        XCTAssertTrue(source.contains("CodePaneRenderAudit.verdict("), """
            some path reachable from drawHashMarksAndLabels must hand its Measurements to \
            CodePaneRenderAudit.verdict( — this may live in a different method than \
            drawHashMarksAndLabels itself (e.g. a closure/hook it calls), but if verdict( is never \
            invoked at all the audit computes a verdict nobody ever reads, which is the same as not \
            having a tripwire.
            """)
    }

    // MARK: 30. The off-by-one guard's counter arithmetic survives untouched

    func testRowIncrementGuardArithmeticIsUnperturbedByTheAuditWiring() throws {
        let source = try Self.codeContentViewSource()
        let rowIncrementLines = Self.lines(containing: "row += 1", in: source)
        XCTAssertEqual(rowIncrementLines.count, 1, """
            "row += 1" must appear exactly once in CodeContentView.swift — this counter is the fix for \
            a real, previously-shipped off-by-one bug (see the large comment above it in \
            drawHashMarksAndLabels), and this diagnostics job must not perturb it, whether by \
            duplicating it, deleting it, or introducing a second increment site while wiring in the \
            audit:
            \(rowIncrementLines.joined(separator: "\n"))
            """)

        XCTAssertTrue(source.contains("if !isFirstFragment && isParagraphStart"), """
            the guard condition that gates "row += 1" — if !isFirstFragment && isParagraphStart — must \
            still be present verbatim; this is the exact condition the off-by-one fix depends on, and \
            this diagnostics job touches drawHashMarksAndLabels only to add measurement/audit code \
            around it, never to change when the row counter advances.
            """)
    }

    // MARK: - Helpers

    /// `CodeContentView.swift` is not compiled into this target, so it has to
    /// be read as text — same idiom as `ImageDecodePolicyTests.sourceRoot` and
    /// `TurnInteractionWiringTests.replViewSource()`.
    private static func codeContentViewSource() throws -> String {
        try String(contentsOf: sourceRoot.appendingPathComponent("UI/Views/CodeContentView.swift"), encoding: .utf8)
    }

    private static func dynamicFocusViewSource() throws -> String {
        try String(contentsOf: sourceRoot.appendingPathComponent("UI/Views/DynamicFocusView.swift"), encoding: .utf8)
    }

    private static var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)          // …/macOS/NostromoTests/CodeContentViewTests.swift
            .deletingLastPathComponent()          // …/macOS/NostromoTests
            .deletingLastPathComponent()          // …/macOS
            .appendingPathComponent("Nostromo")
    }

    /// Every line containing `needle`, in order.
    private static func lines(containing needle: String, in source: String) -> [String] {
        source.components(separatedBy: "\n").filter { $0.contains(needle) }
    }

    /// Every call `marker` … `)` in `source`, matching parentheses so a nested
    /// call doesn't truncate the match. Mirrors
    /// `TurnInteractionWiringTests.balancedCalls`.
    private static func balancedCalls(startingAt marker: String, in source: String) -> [String] {
        var calls: [String] = []
        var searchStart = source.startIndex
        while let markerRange = source.range(of: marker, range: searchStart..<source.endIndex) {
            var depth = 1   // `marker` already includes the opening "("
            var idx = markerRange.upperBound
            while idx < source.endIndex, depth > 0 {
                if source[idx] == "(" { depth += 1 }
                if source[idx] == ")" { depth -= 1 }
                idx = source.index(after: idx)
            }
            calls.append(String(source[markerRange.lowerBound..<idx]))
            searchStart = idx
        }
        return calls
    }

    /// Every occurrence of `marker` in `source` that is neither its own `func`
    /// definition nor preceded — within the same function — by a
    /// `case .scrollTo`. Scoping "the same function" to "since the nearest
    /// preceding `func` keyword" is a loose approximation, but a robust one:
    /// it can't be fooled by reformatting, only by another `func` being
    /// inserted between the `case .scrollTo` and the call, which would be a
    /// far stranger change than this test is trying to guard against.
    private static func occurrencesOutsideScrollToBranch(of marker: String, in source: String) -> [String] {
        var violations: [String] = []
        var searchStart = source.startIndex
        let funcSignature = "func " + marker.dropLast()   // "scrollRowToCentre(" -> "func scrollRowToCentre"

        while let occurrence = source.range(of: marker, range: searchStart..<source.endIndex) {
            defer { searchStart = occurrence.upperBound }

            let lineStart = source.lineRange(for: occurrence).lowerBound
            let line = source[lineStart..<source.lineRange(for: occurrence).upperBound]
            if line.contains(funcSignature) { continue }   // its own definition

            let precedingFunc = source.range(
                of: "func ", options: .backwards, range: source.startIndex..<occurrence.lowerBound
            )
            let scopeStart = precedingFunc?.lowerBound ?? source.startIndex
            let scope = source[scopeStart..<occurrence.lowerBound]
            if !scope.contains("case .scrollTo") {
                violations.append(String(line).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return violations
    }
}
