import XCTest

// `CodePaneRenderAudit` is compiled into this target directly (logic test —
// no host app, no `@testable import`), the same idiom as `ScrollDecisionTests`
// and `RowOffsetIndexTests`.

/// Behavioural coverage for `CodePaneRenderAudit` — the tripwire that turns a
/// single `drawHashMarksAndLabels` pass's measurements into a verdict about
/// whether the code pane rendered a blank body under a correct gutter.
///
/// The controlling invariant (D2, dictated by the diagnostics plan, not a
/// design choice made here): the three `Reason` terms are only ever consulted
/// — and `.blankBody` only ever fires — when the ruler actually painted at
/// least one label AND the text storage actually has content. Absent either
/// of those two facts, there is no evidence either way, and the verdict must
/// be `.healthy` no matter what the width fields say.
final class CodePaneRenderAuditTests: XCTestCase {

    // MARK: - Fixtures

    /// A pane with plenty of room in every dimension and content painted —
    /// the case the audit must never flag.
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
            textKitDowngraded: false
        )
    }

    /// The exact measurements read off the screenshot that motivated this
    /// diagnostics job: gutter fully painted, body collapsed to zero width.
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
            textKitDowngraded: false
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
            document-view terms failed.
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
            textKitDowngraded: false
        )
        XCTAssertEqual(CodePaneRenderAudit.verdict(measurements), .healthy, """
            an empty pane — before its first push, or right after clearContent() \
            — must not trip the wire just because every width happens to read zero.
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
            textKitDowngraded: false
        )
        XCTAssertEqual(CodePaneRenderAudit.verdict(measurements), .healthy, """
            the ruler having drawn zero labels this pass — a legitimately hidden \
            or mid-layout pane — means there is no evidence either way, even \
            though the text storage is non-empty and every width is zero.
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
}
