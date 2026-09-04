import Foundation

/// The judgement half of the code-pane render tripwire (diagnostics job:
/// `.claude/plans/instrument-code-pane-render-diagnostics.md`).
///
/// `CodeContentView`'s `LineNumberRulerView.drawHashMarksAndLabels` is the one
/// place in the program guaranteed to run at the instant a paint either
/// happens or doesn't — so it measures. Everything it measures gets handed
/// here, Foundation-only, so the judgement compiles into the host-less
/// `NostromoTests` target and is unit-testable without a window server (D3),
/// the same discipline `CodeDocument`, `DiffDocument`, `RowOffsetIndex`, and
/// `ScrollDecision` already follow.
///
/// ## The invariant (D2)
///
/// If the ruler painted at least one non-empty label over a non-empty text
/// storage, the text view must have been *capable* of painting that content:
/// its text container must have had usable width, its own frame must have
/// been wider than the gutter it sits beside, and the clip view showing it
/// must have had width. Any one of those failing while the ruler still drew
/// real numbers is exactly "ruler right, body blank" — the bug this
/// diagnostics job exists to catch with no operator present and no repro.
///
/// Absent either half of that premise — no labels painted, or no text at all
/// — there is no evidence either way, and the verdict is `.healthy`
/// regardless of what the widths read. A pane before its first push, a pane
/// just cleared, and a pane that is legitimately hidden or mid-layout all
/// look like that, and none of them may trip the wire — a tripwire that
/// fires on a healthy pane is worse than no tripwire at all.
enum CodePaneRenderAudit {

    /// Everything `drawHashMarksAndLabels` can observe about one draw pass,
    /// plus the ruler's own inputs needed to state the invariant.
    struct Measurements: Equatable {
        /// How many non-empty labels this draw pass actually painted.
        var labelsPainted: Int
        /// `gutterLabels.count` — the labels the document believes it has.
        var labelCount: Int
        /// `textView.textStorage?.length ?? 0`.
        var textStorageLength: Int
        /// `rowOffsets.count` — the document's row count.
        var rowCount: Int
        /// `textView.frame.width` — the document view's own frame.
        var documentViewWidth: Double
        /// `scrollView.contentView.bounds.width`.
        var clipViewWidth: Double
        /// `layoutManager.usedRect(for: container).width`.
        var containerUsedWidth: Double
        /// The ruler's current `ruleThickness`.
        var ruleThickness: Double
        /// `textView.textLayoutManager == nil` — a TextKit 2 → TextKit 1
        /// downgrade (H2). Evidence for a hypothesis about *why*, never
        /// itself a verdict term.
        var textKitDowngraded: Bool

        /// The "no draw pass has happened yet" state — every field zeroed.
        /// `verdict(_:)` reads this as `.healthy` (labelsPainted/textStorageLength
        /// are both 0), which is exactly right for a pane that hasn't rendered
        /// anything to judge yet. The named default `CodeContentView` seeds
        /// `lastMeasurements` with before the first draw pass reports in.
        static let empty = Measurements(
            labelsPainted: 0, labelCount: 0, textStorageLength: 0, rowCount: 0,
            documentViewWidth: 0, clipViewWidth: 0, containerUsedWidth: 0,
            ruleThickness: 0, textKitDowngraded: false
        )
    }

    /// A term of the blank-body invariant that failed.
    enum Reason: String, Equatable {
        case textContainerHasNoUsableWidth  = "text container used width is <= 0"
        case documentViewNarrowerThanGutter = "document view width is <= the gutter's rule thickness"
        case clipViewHasNoWidth             = "clip view width is <= 0"
    }

    enum Verdict: Equatable {
        case healthy
        case blankBody(reasons: [Reason])
    }

    /// Judge one draw pass. See the invariant above — the two-part guard is
    /// load-bearing: `labelsPainted > 0 && textStorageLength > 0` is what
    /// keeps an empty, cleared, or hidden pane from ever being flagged.
    static func verdict(_ m: Measurements) -> Verdict {
        guard m.labelsPainted > 0, m.textStorageLength > 0 else { return .healthy }

        var reasons: [Reason] = []
        if m.containerUsedWidth <= 0 { reasons.append(.textContainerHasNoUsableWidth) }
        if m.documentViewWidth <= m.ruleThickness { reasons.append(.documentViewNarrowerThanGutter) }
        if m.clipViewWidth <= 0 { reasons.append(.clipViewHasNoWidth) }
        return reasons.isEmpty ? .healthy : .blankBody(reasons: reasons)
    }

    /// One deterministic line for the `codepane` log — also the rate
    /// limiter's dedup key, so a pane redrawing at scroll rate logs once per
    /// distinct verdict rather than once per frame.
    static func summary(of m: Measurements) -> String {
        let verdictText: String
        switch verdict(m) {
        case .healthy:
            verdictText = "healthy"
        case .blankBody(let reasons):
            verdictText = "blankBody[\(reasons.map(\.rawValue).joined(separator: "; "))]"
        }
        return "verdict=\(verdictText) labelsPainted=\(m.labelsPainted)/\(m.labelCount) " +
               "textStorageLength=\(m.textStorageLength) rowCount=\(m.rowCount) " +
               "documentViewWidth=\(m.documentViewWidth) clipViewWidth=\(m.clipViewWidth) " +
               "containerUsedWidth=\(m.containerUsedWidth) ruleThickness=\(m.ruleThickness) " +
               "textKitDowngraded=\(m.textKitDowngraded)"
    }

    /// Multi-line report for Debug ▸ Copy code-pane diagnostics.
    static func report(of m: Measurements) -> String {
        """
        verdict: \(verdict(m))
        labels painted: \(m.labelsPainted) / \(m.labelCount)
        text storage length: \(m.textStorageLength)
        row count: \(m.rowCount)
        document view width: \(m.documentViewWidth)
        clip view width: \(m.clipViewWidth)
        container used width: \(m.containerUsedWidth)
        rule thickness: \(m.ruleThickness)
        TextKit 1 downgrade: \(m.textKitDowngraded)
        """
    }
}
