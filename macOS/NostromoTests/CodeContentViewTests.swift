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

    // MARK: 31. W3 — the ruler must clip its fill to its own bounds

    /// This is the test that fails against `main`: the empirically confirmed root cause of
    /// "correct gutter, blank body, no tab strip, no caption" (W3) is that
    /// `drawHashMarksAndLabels` fills the raw dirty rect AppKit hands it rather than clipping to
    /// its own bounds. `NSView.clipsToBounds` has defaulted to `false` since macOS 14, and this
    /// ruler is ordered after the `NSClipView` in the scroll view's subviews — so an unclipped
    /// fill paints solid black over the whole document view below it and the 26pt
    /// `TabRegionView` tab strip immediately above the scroll view. Measured live on macOS 26.5:
    /// `rect` was `(0, -32, 880, 234)` for a ruler whose own `bounds` were `(0, 0, 40, 200)`; with
    /// `rect.intersection(bounds).fill()` instead, bright body pixels went from 0 to 32943 and a
    /// cornflower tab strip survived above the scroll view (22880 px vs 0). There is no tree
    /// divergence and no TextKit split-brain — it is this one unclipped `rect.fill()`.
    func testDrawHashMarksAndLabelsFillsOnlyItsOwnBoundsNeverTheRawDirtyRect() throws {
        let source = try Self.codeContentViewSource()
        guard let body = Self.functionBody(
            signature: "override func drawHashMarksAndLabels(in rect: NSRect) {", in: source
        ) else {
            XCTFail("drawHashMarksAndLabels(in rect:) not found — did it move or rename?")
            return
        }
        XCTAssertFalse(body.contains("rect.fill()"), """
            drawHashMarksAndLabels must never fill the raw `rect` AppKit hands it — that rect is \
            the dirty rect of the *whole enclosing NSScrollView*, not this ruler's own 40pt-wide \
            bounds (measured live as (0, -32, 880, 234) for a 40x200 ruler). Filling it \
            unclipped paints black over the entire code/diff text body and the tab strip above \
            the scroll view, which is exactly the "correct gutter, blank body" bug this \
            diagnostics job exists to fix. This test fails against `main`.
            """)
        XCTAssertTrue(body.contains("rect.intersection(bounds)"), """
            drawHashMarksAndLabels must compute and fill rect.intersection(bounds) instead of the \
            raw rect — clipping the AppKit-supplied dirty rect to the ruler's own bounds before \
            filling is what stops the fill from ever reaching past the gutter into the body or \
            the tab strip above it.
            """)
    }

    func testLineNumberRulerViewOptsIntoClipsToBoundsInInit() throws {
        let source = try Self.codeContentViewSource()
        guard let body = Self.functionBody(signature: "init(textView: NSTextView) {", in: source) else {
            XCTFail("LineNumberRulerView.init(textView:) not found — did it move or rename?")
            return
        }
        XCTAssertTrue(body.contains("clipsToBounds = true"), """
            LineNumberRulerView.init must set clipsToBounds = true. NSView.clipsToBounds has \
            defaulted to false since macOS 14 — this ruler relying on rect.intersection(bounds) \
            alone in drawHashMarksAndLabels is the actual fix, but this is belt-and-braces for \
            any future drawing this view grows that might forget to clip by hand.
            """)
    }

    func testMeasurementsConstructionFeedsGutterFillWidthFromTheClippedFillRectNotTheRawRect() throws {
        let source = try Self.codeContentViewSource()
        let calls = Self.balancedCalls(startingAt: "CodePaneRenderAudit.Measurements(", in: source)
        XCTAssertFalse(calls.isEmpty, "CodePaneRenderAudit.Measurements( call site not found — did it move or rename?")
        for call in calls {
            XCTAssertTrue(call.contains("gutterFillWidth:"), """
                the Measurements(...) construction must pass gutterFillWidth: — the width the \
                ruler actually filled this pass — or the gutterFillWiderThanGutter guard this \
                whole W3 fix depends on has nothing to compare against and can never fire again \
                on a recurrence: \(call)
                """)
            XCTAssertTrue(call.contains("documentViewHeight:"), """
                the Measurements(...) construction must pass documentViewHeight:, or G1's \
                documentViewShorterThanItsText guard has nothing to compare against: \(call)
                """)
            XCTAssertTrue(call.contains("clipViewHeight:"), """
                the Measurements(...) construction must pass clipViewHeight: — no longer consulted \
                by any verdict term, but still required for the diagnostic report an operator \
                pastes into a bug report: \(call)
                """)
            XCTAssertTrue(call.contains("containerUsedHeight:"), """
                the Measurements(...) construction must pass containerUsedHeight: — the height of \
                the text layoutManager actually laid out (usedRect plus insets) — or G1's \
                documentViewShorterThanItsText guard has nothing to compare the document view \
                against: \(call)
                """)
            XCTAssertTrue(call.contains("gutterFillWidth: Double(fill.width)"), """
                gutterFillWidth must be fed from the clipped fill rect — `fill.width`, where \
                `fill = rect.intersection(bounds)` — not from the raw, unclipped `rect` this \
                diagnostics job exists to stop trusting. Feeding it from rect.width would make \
                the very guard meant to catch an unclipped fill blind to the unclipped fill: \
                \(call)
                """)
        }
    }

    func testAttemptRenderRecoveryReassertsHeightAsWellAsWidthAndStillRunsAfterThePreRepairLogLine() throws {
        let source = try Self.codeContentViewSource()

        guard let recoveryBody = Self.functionBody(
            signature: "private func attemptRenderRecovery() {", in: source
        ) else {
            XCTFail("attemptRenderRecovery() not found — did it move or rename?")
            return
        }
        XCTAssertTrue(recoveryBody.contains("bounds.width"), """
            attemptRenderRecovery must keep its existing width re-assertion (addresses H1: a \
            collapsed text container) — this diagnostics job adds a height re-assertion \
            alongside it, not instead of it.
            """)
        XCTAssertTrue(recoveryBody.contains("bounds.height"), """
            attemptRenderRecovery must also re-assert height, alongside its existing width \
            re-assertion — a document view shorter than its clip view (G1) is exactly as capable \
            of producing "correct gutter, blank body" as a collapsed container width is, and a \
            mitigation that only ever touches width leaves that whole failure mode with no \
            corrective action at all.
            """)

        guard let auditBody = Self.functionBody(
            signature: "private func auditAfterDraw(_ measurements: CodePaneRenderAudit.Measurements) {", in: source
        ), let logRange = auditBody.range(of: "codePaneLog.error("),
           let recoveryCallRange = auditBody.range(of: "attemptRenderRecovery()")
        else {
            XCTFail("auditAfterDraw's log-then-mitigate structure not found — did it change shape?")
            return
        }
        XCTAssertTrue(logRange.lowerBound < recoveryCallRange.lowerBound, """
            the pre-repair snapshot must still be logged (codePaneLog.error) strictly before \
            attemptRenderRecovery runs — an operator needs to see what the pane looked like \
            *before* any mitigation touched it, and adding a height re-assertion to the \
            mitigation must not have reordered that.
            """)
    }

    // MARK: 32. G2 — textKitDowngraded is logged unconditionally, not only measured

    /// The previous version of this test only asserted that the substring "textKitDowngraded"
    /// appeared more than once anywhere in the file — which passes even if both real log call
    /// sites were deleted, because the doc comments above them (`logDocumentPush`'s and
    /// `auditAfterDraw`'s) also contain that spelling. This version scopes the check to the two
    /// function bodies that must actually log it, and requires the identifier to sit inside a
    /// real `codePaneLog.info(...)` call within each body — not merely a comment above it.
    func testTextKitDowngradedIsActuallyLoggedSomewhereNotOnlyMeasured() throws {
        let source = try Self.codeContentViewSource()

        let pushBody = try XCTUnwrap(
            Self.functionBody(signature: "private func logDocumentPush(kind: String) {", in: source),
            "logDocumentPush(kind:) not found — did it move or rename?"
        )
        let auditBody = try XCTUnwrap(
            Self.functionBody(
                signature: "private func auditAfterDraw(_ measurements: CodePaneRenderAudit.Measurements) {",
                in: source
            ),
            "auditAfterDraw(_:) not found — did it move or rename?"
        )

        for (name, body) in [("logDocumentPush", pushBody), ("auditAfterDraw", auditBody)] {
            let logCalls = Self.balancedCalls(startingAt: "codePaneLog.info(", in: body)
            let mentionsTextKitDowngraded = logCalls.contains { $0.contains("textKitDowngraded") }
            XCTAssertTrue(mentionsTextKitDowngraded, """
                \(name) must contain a codePaneLog.info(...) call whose logged string interpolates \
                textKitDowngraded (G2) — a flag that is only ever written into a Measurements \
                struct and never logged is not evidence of anything. A doc comment mentioning the \
                identifier does not satisfy this: only an actual codePaneLog.info( call site \
                counts. codePaneLog.info(...) calls found in \(name): \(logCalls)
                """)
        }
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

    /// The brace-balanced body of the function/initializer whose signature line is exactly
    /// `signature` (e.g. `"init(textView: NSTextView) {"`), or `nil` if that signature isn't
    /// found. Mirrors `balancedCalls`'s parenthesis matching, applied to `{`/`}` around a
    /// function body instead — so a nested closure or `if` block inside the function can't
    /// truncate the match.
    private static func functionBody(signature: String, in source: String) -> String? {
        // `signature` ends with the body's own opening brace, so
        // `sigRange.upperBound` is already the first character of the body and
        // the brace depth is already 1. Searching for the *next* `{` from here
        // would silently start the body at some inner block — which reads as
        // an empty match to every `contains` assertion below, i.e. a passing
        // test that checked nothing.
        guard let sigRange = source.range(of: signature) else { return nil }
        var depth = 1
        var idx = sigRange.upperBound
        while idx < source.endIndex, depth > 0 {
            if source[idx] == "{" { depth += 1 }
            if source[idx] == "}" { depth -= 1 }
            idx = source.index(after: idx)
        }
        guard depth == 0 else { return nil }
        return String(source[sigRange.upperBound..<idx])
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
