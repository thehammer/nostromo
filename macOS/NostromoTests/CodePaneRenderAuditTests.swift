import XCTest

// `CodePaneRenderAudit` is compiled into this target directly (logic test —
// no host app, no `@testable import`), the same idiom as `ScrollDecisionTests`
// and `RowOffsetIndexTests`.

/// Behavioural coverage for `CodePaneRenderAudit` — the tripwire that turns a
/// single `drawHashMarksAndLabels` pass's measurements into a verdict about
/// whether the code pane rendered a blank body under a correct gutter.
///
/// The controlling invariant (D2, dictated by the diagnostics plan, not a
/// design choice made here): the terms below are only ever consulted — and
/// `.blankBody` only ever fires — when the ruler actually painted at least
/// one label AND the text storage actually has content. Absent either of
/// those two facts, there is no evidence either way, and the verdict must be
/// `.healthy` no matter what the width/height/plausibility fields say.
///
/// ## W3 — the real recurrence this file failed to catch three times over
///
/// The first three width terms (`textContainerHasNoUsableWidth`,
/// `documentViewNarrowerThanGutter`, `clipViewHasNoWidth`) were written
/// against a *theory* of the blank-body bug: a collapsed text container or
/// clip view. The empirically confirmed root cause is different and was
/// invisible to all three: `LineNumberRulerView.drawHashMarksAndLabels`
/// filled the *raw dirty rect* AppKit handed it — the whole scroll view,
/// `clipsToBounds` defaulting to `false` since macOS 14 — rather than
/// clipping to its own `bounds`. Every width term above can read perfectly
/// healthy while that unclipped fill paints black over the text body and the
/// tab strip above it. `gutterFillWiderThanGutter` is the term that actually
/// catches it: it compares what the ruler *filled* this pass
/// (`rect.intersection(bounds).width`) against its own `ruleThickness`.
///
/// `documentViewShorterThanViewport` and `textStorageImplausiblyShortForRowCount`
/// are two more guards from the same investigation, aimed at hypotheses that
/// turned out not to be this bug but are cheap, low-false-positive tripwires
/// worth keeping.
final class CodePaneRenderAuditTests: XCTestCase {

    // MARK: - Fixtures

    /// A pane with plenty of room in every dimension and content painted —
    /// the case the audit must never flag. `gutterFillWidth` equals
    /// `ruleThickness` (the ruler filled exactly its own bounds, the healthy
    /// case post-fix) and the document view is taller than the clip view (an
    /// ordinary scrollable document).
    private static func healthyMeasurements() -> CodePaneRenderAudit.Measurements {
        CodePaneRenderAudit.Measurements(
            labelsPainted: 24,
            labelCount: 24,
            textStorageLength: 900,
            rowCount: 24,
            documentViewWidth: 640,
            clipViewWidth: 840,
            containerUsedWidth: 600,
            ruleThickness: 48,
            gutterFillWidth: 48,
            documentViewHeight: 800,
            clipViewHeight: 600,
            textKitDowngraded: false
        )
    }

    /// The exact measurements read off the screenshot that motivated this
    /// diagnostics job: gutter fully painted, body collapsed to zero width.
    /// `gutterFillWidth`/heights are healthy here — this fixture is about the
    /// two *width* terms only, not the W3 gutter-fill term.
    private static func screenshotSignature() -> CodePaneRenderAudit.Measurements {
        CodePaneRenderAudit.Measurements(
            labelsPainted: 24,
            labelCount: 24,
            textStorageLength: 900,
            rowCount: 24,
            documentViewWidth: 0,
            clipViewWidth: 840,
            containerUsedWidth: 0,
            ruleThickness: 48,
            gutterFillWidth: 48,
            documentViewHeight: 800,
            clipViewHeight: 600,
            textKitDowngraded: false
        )
    }

    /// The real numbers measured live (macOS 26.5) on the W3 sighting: a
    /// ruler with `ruleThickness: 40` whose `drawHashMarksAndLabels` filled a
    /// rect `(0, -32, 880, 234)` — the whole enclosing `NSScrollView`, 32pt
    /// taller than the ruler and above its own origin — because `rect` (the
    /// AppKit-supplied dirty rect) was never intersected with the ruler's own
    /// `bounds`. Every width and height term here is deliberately healthy:
    /// this is the fixture that proves those six terms are not sufficient on
    /// their own.
    private static func w3GutterOverpaintSignature() -> CodePaneRenderAudit.Measurements {
        CodePaneRenderAudit.Measurements(
            labelsPainted: 10,
            labelCount: 10,
            textStorageLength: 400,
            rowCount: 10,
            documentViewWidth: 840,
            clipViewWidth: 880,
            containerUsedWidth: 394,
            ruleThickness: 40,
            gutterFillWidth: 880,
            documentViewHeight: 202,
            clipViewHeight: 200,
            textKitDowngraded: true
        )
    }

    // MARK: 1. A healthy pane never trips the wire

    func testHealthyPaneWithPositiveWidthsAndPaintedLabelsIsHealthy() {
        XCTAssertEqual(CodePaneRenderAudit.verdict(Self.healthyMeasurements()), .healthy)
    }

    // MARK: 2. The exact screenshot signature is flagged, with the right reasons

    func testScreenshotSignatureIsBlankBodyWithContainerAndDocumentViewReasonsOnly() {
        let verdict = CodePaneRenderAudit.verdict(Self.screenshotSignature())
        guard case .blankBody(let reasons) = verdict else {
            return XCTFail("expected .blankBody for the screenshot signature, got \(verdict)")
        }
        XCTAssertEqual(reasons, [.textContainerHasNoUsableWidth, .documentViewNarrowerThanGutter], """
            clipViewWidth is 840 (positive) in the screenshot signature, so \
            .clipViewHasNoWidth must NOT appear — only the container and \
            document-view terms failed. gutterFillWidth/heights are healthy \
            in this fixture, so none of the W3 terms should fire either.
            """)
    }

    // MARK: 3. Negative #1 — a genuinely empty pane (no evidence) is healthy

    func testGenuinelyEmptyPaneBeforeFirstPushIsHealthyRegardlessOfZeroWidths() {
        let measurements = CodePaneRenderAudit.Measurements(
            labelsPainted: 0,
            labelCount: 0,
            textStorageLength: 0,
            rowCount: 0,
            documentViewWidth: 0,
            clipViewWidth: 0,
            containerUsedWidth: 0,
            ruleThickness: 48,
            gutterFillWidth: 0,
            documentViewHeight: 0,
            clipViewHeight: 0,
            textKitDowngraded: false
        )
        XCTAssertEqual(CodePaneRenderAudit.verdict(measurements), .healthy, """
            an empty pane — before its first push, or right after clearContent() \
            — must not trip the wire just because every width/height happens to \
            read zero.
            """)
    }

    // MARK: 4. Negative #2 — hidden/mid-layout pane (no labels painted) is healthy

    func testPaneWithContentButNoPaintedLabelsIsHealthyRegardlessOfWidths() {
        let measurements = CodePaneRenderAudit.Measurements(
            labelsPainted: 0,
            labelCount: 24,
            textStorageLength: 900,
            rowCount: 24,
            documentViewWidth: 0,
            clipViewWidth: 0,
            containerUsedWidth: 0,
            ruleThickness: 48,
            gutterFillWidth: 0,
            documentViewHeight: 0,
            clipViewHeight: 0,
            textKitDowngraded: false
        )
        XCTAssertEqual(CodePaneRenderAudit.verdict(measurements), .healthy, """
            the ruler having drawn zero labels this pass — a legitimately hidden \
            or mid-layout pane — means there is no evidence either way, even \
            though the text storage is non-empty and every width/height is zero.
            """)
    }

    // MARK: 5. textKitDowngraded is evidence for a hypothesis, never itself a fault

    func testTextKitDowngradedOnAnOtherwiseHealthyPaneIsStillHealthy() {
        var measurements = Self.healthyMeasurements()
        measurements.textKitDowngraded = true
        XCTAssertEqual(CodePaneRenderAudit.verdict(measurements), .healthy, """
            textKitDowngraded is H2 evidence for a hypothesis about *why* a \
            blank body happened — it must never itself be treated as a fault.
            """)
    }

    func testReportReflectsTextKitDowngradedFlag() {
        var downgraded = Self.healthyMeasurements()
        downgraded.textKitDowngraded = true
        var notDowngraded = Self.healthyMeasurements()
        notDowngraded.textKitDowngraded = false

        let downgradedReport = CodePaneRenderAudit.report(of: downgraded)
        let notDowngradedReport = CodePaneRenderAudit.report(of: notDowngraded)

        XCTAssertNotEqual(downgradedReport, notDowngradedReport, """
            report(of:) must mention textKitDowngraded — flipping only that \
            field must change the report text, or the flag is invisible in the \
            pasteboard report an operator would paste into a bug report.
            """)
    }

    // MARK: 6. summary(of:) is deterministic — the rate-limiter dedupes on it

    func testSummaryIsDeterministicForEqualMeasurements() {
        let a = Self.screenshotSignature()
        let b = Self.screenshotSignature()
        XCTAssertEqual(a, b, "sanity: the two fixtures must actually be Equatable-equal")
        XCTAssertEqual(CodePaneRenderAudit.summary(of: a), CodePaneRenderAudit.summary(of: b), """
            summary(of:) must be a pure function of Measurements — the \
            rate-limiter that sits on top of this type dedupes log lines by \
            comparing summary(of:) output, so two equal Measurements values \
            must never produce two different summaries.
            """)

        // Calling it twice on the exact same value must also agree.
        XCTAssertEqual(CodePaneRenderAudit.summary(of: a), CodePaneRenderAudit.summary(of: a))
    }

    // MARK: 7. summary(of:) actually reflects the verdict, not a constant string

    func testSummaryDiffersBetweenTheScreenshotSignatureAndAHealthyPane() {
        let blankBodySummary = CodePaneRenderAudit.summary(of: Self.screenshotSignature())
        let healthySummary = CodePaneRenderAudit.summary(of: Self.healthyMeasurements())
        XCTAssertNotEqual(blankBodySummary, healthySummary, """
            summary(of:) must vary with the underlying measurements/verdict — a \
            constant string would make the rate-limiter's dedup key meaningless.
            """)
    }

    // MARK: 8. W3 — the real sighting's signature (the headline failing-first test)

    func testGutterFillingTheWholeScrollViewIsBlankBodyEvenWithEveryWidthAndHeightTermHealthy() {
        let verdict = CodePaneRenderAudit.verdict(Self.w3GutterOverpaintSignature())
        guard case .blankBody(let reasons) = verdict else {
            return XCTFail("""
                expected .blankBody for the W3 gutter-overpaint signature, got \(verdict). \
                Against `main` (pre-W3-fix) this fixture returns .healthy — every one of the \
                three pre-existing width terms passes (containerUsedWidth=394>0, \
                documentViewWidth=840>ruleThickness=40, clipViewWidth=880>0) and there was no \
                height or plausibility term at all — which is exactly why three prior \
                investigations of "correct gutter, blank body" missed this bug: the audit had \
                no term that could see an unclipped `rect.fill()` painting over the body and the \
                tab strip above it. gutterFillWiderThanGutter (gutterFillWidth=880 > \
                ruleThickness=40) is the only term that catches it.
                """)
        }
        XCTAssertEqual(reasons, [.gutterFillWiderThanGutter], """
            only the gutter-fill term should fire for this exact sighting — every width and \
            height term in this fixture is individually healthy, so if any other reason \
            appears here, the guard conditions for that term have drifted.
            """)
    }

    // MARK: 9. W3 — the fixed pane is healthy (the "the fix works" pin)

    func testFixedGutterFillEqualToRuleThicknessMakesTheSameSightingHealthy() {
        var fixed = Self.w3GutterOverpaintSignature()
        fixed.gutterFillWidth = 40 // == ruleThickness: rect.intersection(bounds) instead of rect
        XCTAssertEqual(CodePaneRenderAudit.verdict(fixed), .healthy, """
            once drawHashMarksAndLabels fills rect.intersection(bounds) instead of the raw \
            dirty rect, gutterFillWidth collapses to ruleThickness and this exact sighting must \
            read as healthy — this is the assertion that pins "the fix actually works," not just \
            "the bug is detected."
            """)
    }

    // MARK: 10. W3 boundary — > not >=

    func testGutterFillWidthExactlyEqualToRuleThicknessIsHealthyNotFlagged() {
        var measurements = Self.healthyMeasurements()
        measurements.ruleThickness = 48
        measurements.gutterFillWidth = 48 // exactly equal, not less
        XCTAssertEqual(CodePaneRenderAudit.verdict(measurements), .healthy, """
            the gutterFillWiderThanGutter guard must be a strict `>`, not `>=` — the ruler is \
            *expected* to fill exactly its own rule thickness every healthy pass, so `>=` here \
            would make every healthy pane flag itself.
            """)
    }

    // MARK: 11. G1 — document view shorter than the viewport

    func testDocumentViewShorterThanClipViewTripsTheHeightTerm() {
        var measurements = Self.healthyMeasurements()
        measurements.documentViewHeight = 0
        measurements.clipViewHeight = 200
        let verdict = CodePaneRenderAudit.verdict(measurements)
        guard case .blankBody(let reasons) = verdict else {
            return XCTFail("expected .blankBody when the document view collapsed under the viewport, got \(verdict)")
        }
        XCTAssertTrue(reasons.contains(.documentViewShorterThanViewport), """
            a document view shorter than the clip view showing it means the text view could not \
            possibly have painted its full content — this is a second, independent way a \
            "correct gutter, blank body" render can happen, and must be caught the same as the \
            gutter-fill term.
            """)
    }

    // MARK: 12. G1 negative — the ordinary cases must never trip it

    func testDocumentViewTallerThanClipViewByMoreThanOnePointIsHealthy() {
        var measurements = Self.healthyMeasurements()
        measurements.documentViewHeight = 202
        measurements.clipViewHeight = 200
        XCTAssertEqual(CodePaneRenderAudit.verdict(measurements), .healthy, """
            a document taller than its viewport is the normal, scrollable case and must never \
            be flagged.
            """)
    }

    func testDocumentViewExactlyEqualToClipViewHeightIsHealthy() {
        var measurements = Self.healthyMeasurements()
        measurements.documentViewHeight = 200
        measurements.clipViewHeight = 200
        XCTAssertEqual(CodePaneRenderAudit.verdict(measurements), .healthy, """
            a document exactly filling its viewport (no scrollable overflow) is healthy — the \
            deliberate 1pt tolerance in the guard exists precisely so this common case, and \
            ordinary floating-point layout noise around it, is never mistaken for a collapsed \
            document view.
            """)
    }

    func testZeroClipViewHeightNeverTripsTheHeightTermRegardlessOfDocumentHeight() {
        var midLayout = Self.healthyMeasurements()
        midLayout.clipViewHeight = 0
        midLayout.documentViewHeight = 0
        XCTAssertEqual(CodePaneRenderAudit.verdict(midLayout), .healthy, """
            clipViewHeight == 0 means the scroll view itself hasn't been laid out yet (mid-layout) \
            — there is no viewport to be shorter than, so this must never fire no matter what \
            documentViewHeight reads, including 0.
            """)

        var midLayoutTallDocument = Self.healthyMeasurements()
        midLayoutTallDocument.clipViewHeight = 0
        midLayoutTallDocument.documentViewHeight = 900
        XCTAssertEqual(CodePaneRenderAudit.verdict(midLayoutTallDocument), .healthy, """
            same guard, with a non-zero document height — clipViewHeight == 0 alone must suppress \
            the term.
            """)
    }

    // MARK: 13. G3 — text storage implausibly short for the row count

    func testTextStorageOneShorterThanRowCountTripsThePlausibilityTerm() {
        var measurements = Self.healthyMeasurements()
        measurements.rowCount = 10
        measurements.textStorageLength = 9 // ten empty lines joined by nine newlines: length == rowCount - 1
        let verdict = CodePaneRenderAudit.verdict(measurements)
        guard case .blankBody(let reasons) = verdict else {
            return XCTFail("expected .blankBody for a text storage too short to hold one character per row, got \(verdict)")
        }
        XCTAssertTrue(reasons.contains(.textStorageImplausiblyShortForRowCount), """
            a document of N rows joined by newlines always has length >= N-1; a document \
            reporting exactly N-1 means every single row is empty, which the ruler cannot have \
            10 real labels for — this is the third independent term the W3 investigation added.
            """)
    }

    // MARK: 14. G3 negative — a legitimately blank-line-heavy document must not trip it

    func testLegitimatelyBlankLineHeavyDocumentDoesNotTripThePlausibilityTerm() {
        var measurements = Self.healthyMeasurements()
        measurements.rowCount = 24
        measurements.textStorageLength = 40 // far more than rowCount - 1, but still mostly blank lines
        XCTAssertEqual(CodePaneRenderAudit.verdict(measurements), .healthy, """
            a document that is legitimately mostly blank lines (a real, if unusual, source file) \
            must not be flagged just because its average row is short — this is the negative \
            that keeps the plausibility term from becoming a false-positive machine on sparse \
            files.
            """)
    }

    func testSingleRowDocumentNeverTripsThePlausibilityTermRegardlessOfTextStorageLength() {
        var measurements = Self.healthyMeasurements()
        measurements.rowCount = 1
        measurements.textStorageLength = 5
        XCTAssertEqual(CodePaneRenderAudit.verdict(measurements), .healthy, """
            the plausibility term requires rowCount > 1 (there is no "joined by newlines" \
            constraint to violate for a single-row document) — a one-line document must never \
            trip it no matter how short its content.
            """)
    }

    func testSingleEmptyRowIsHealthyViaThePremiseGuardNotThePlausibilityTerm() {
        let measurements = CodePaneRenderAudit.Measurements(
            labelsPainted: 0,
            labelCount: 1,
            textStorageLength: 0,
            rowCount: 1,
            documentViewWidth: 640,
            clipViewWidth: 840,
            containerUsedWidth: 600,
            ruleThickness: 48,
            gutterFillWidth: 48,
            documentViewHeight: 800,
            clipViewHeight: 600,
            textKitDowngraded: false
        )
        XCTAssertEqual(CodePaneRenderAudit.verdict(measurements), .healthy, """
            a single, genuinely empty row (textStorageLength 0) is healthy via the two-part \
            premise guard — there is no evidence either way — not because the plausibility term \
            happened to pass.
            """)
    }

    // MARK: 15. Multiple reasons compose, in the declared order

    func testAGutterFillFailureAndAWidthFailureBothReportInDeclaredOrder() {
        var measurements = Self.healthyMeasurements()
        measurements.documentViewWidth = 40   // <= ruleThickness (48): trips documentViewNarrowerThanGutter
        measurements.gutterFillWidth = 880     // > ruleThickness (48): trips gutterFillWiderThanGutter
        let verdict = CodePaneRenderAudit.verdict(measurements)
        guard case .blankBody(let reasons) = verdict else {
            return XCTFail("expected .blankBody when both a width term and the gutter-fill term fail, got \(verdict)")
        }
        XCTAssertEqual(reasons, [.documentViewNarrowerThanGutter, .gutterFillWiderThanGutter], """
            verdict(_:) must report every failing term, in the declared order (the three \
            pre-existing width terms, then gutterFillWiderThanGutter, then \
            documentViewShorterThanViewport, then textStorageImplausiblyShortForRowCount) — an \
            operator debugging a real recurrence needs all the evidence, not just the first hit.
            """)
    }

    // MARK: 16. summary(of:)/report(of:) surface every new field

    func testReportReflectsGutterFillWidth() {
        var wide = Self.healthyMeasurements()
        wide.gutterFillWidth = 880
        let healthy = Self.healthyMeasurements()

        XCTAssertNotEqual(CodePaneRenderAudit.summary(of: wide), CodePaneRenderAudit.summary(of: healthy), """
            summary(of:) must mention gutterFillWidth — flipping only that field (and therefore \
            the verdict) must change the log line, or the rate-limiter's dedup key can't tell a \
            gutter-overpaint recurrence from a healthy pass.
            """)
        XCTAssertNotEqual(CodePaneRenderAudit.report(of: wide), CodePaneRenderAudit.report(of: healthy), """
            report(of:) must mention gutterFillWidth — otherwise the field is invisible in the \
            pasteboard report an operator would paste into a bug report.
            """)
    }

    func testReportReflectsDocumentViewHeight() {
        var shorter = Self.healthyMeasurements()
        shorter.documentViewHeight = 0
        let healthy = Self.healthyMeasurements()

        XCTAssertNotEqual(CodePaneRenderAudit.summary(of: shorter), CodePaneRenderAudit.summary(of: healthy), """
            summary(of:) must mention documentViewHeight — flipping only that field must change \
            the log line.
            """)
        XCTAssertNotEqual(CodePaneRenderAudit.report(of: shorter), CodePaneRenderAudit.report(of: healthy), """
            report(of:) must mention documentViewHeight, or an operator's pasted report can't \
            distinguish a collapsed document view from a healthy one.
            """)
    }

    func testReportReflectsClipViewHeight() {
        var zero = Self.healthyMeasurements()
        zero.clipViewHeight = 0
        let healthy = Self.healthyMeasurements()

        XCTAssertNotEqual(CodePaneRenderAudit.summary(of: zero), CodePaneRenderAudit.summary(of: healthy), """
            summary(of:) must mention clipViewHeight — flipping only that field must change the \
            log line.
            """)
        XCTAssertNotEqual(CodePaneRenderAudit.report(of: zero), CodePaneRenderAudit.report(of: healthy), """
            report(of:) must mention clipViewHeight, or the field is invisible in the pasted \
            report.
            """)
    }
}
