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
/// ## What the width terms alone could not see (W3)
///
/// Those three terms were written against a *theory* — a collapsed container
/// or clip view — and the confirmed root cause turned out to be none of them:
/// the ruler itself filled the raw dirty rect AppKit handed it (the whole
/// enclosing scroll view; `NSView.clipsToBounds` has defaulted to `false`
/// since macOS 14) instead of clipping to its own bounds, painting black over
/// a text body whose every width read perfectly healthy. `gutterFillWidth` /
/// `gutterFillWiderThanGutter` is the term that catches *that*: it compares
/// what the ruler actually filled against how wide the ruler is allowed to
/// be. The two remaining new terms — a document view shorter than its
/// viewport, and a text storage too short to hold one character per row —
/// close the other two blind spots the same investigation found.
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
        /// The width the ruler actually *filled* this pass —
        /// `rect.intersection(bounds).width`, not the raw `rect.width`. Fed
        /// from the clipped rect on purpose: reporting the AppKit-supplied
        /// dirty rect here would make the guard below blind to exactly the
        /// unclipped fill it exists to catch.
        var gutterFillWidth: Double
        /// `textView.frame.height` — the document view's own frame.
        var documentViewHeight: Double
        /// `scrollView.contentView.bounds.height`.
        var clipViewHeight: Double
        /// `textView.textLayoutManager == nil` — a TextKit 2 → TextKit 1
        /// downgrade. Evidence for a hypothesis about *why*, never itself a
        /// verdict term. (W3 refuted the hypothesis it was added for: the
        /// downgrade is real and harmless — an identical pane with the ruler
        /// removed is downgraded too and paints fine.)
        var textKitDowngraded: Bool

        /// The "no draw pass has happened yet" state — every field zeroed.
        /// `verdict(_:)` reads this as `.healthy` (labelsPainted/textStorageLength
        /// are both 0), which is exactly right for a pane that hasn't rendered
        /// anything to judge yet. The named default `CodeContentView` seeds
        /// `lastMeasurements` with before the first draw pass reports in.
        static let empty = Measurements(
            labelsPainted: 0, labelCount: 0, textStorageLength: 0, rowCount: 0,
            documentViewWidth: 0, clipViewWidth: 0, containerUsedWidth: 0,
            ruleThickness: 0, gutterFillWidth: 0, documentViewHeight: 0,
            clipViewHeight: 0, textKitDowngraded: false
        )
    }

    /// A term of the blank-body invariant that failed.
    enum Reason: String, Equatable {
        case textContainerHasNoUsableWidth  = "text container used width is <= 0"
        case documentViewNarrowerThanGutter = "document view width is <= the gutter's rule thickness"
        case clipViewHasNoWidth             = "clip view width is <= 0"
        case gutterFillWiderThanGutter      = "the gutter filled a rect wider than its own rule thickness (it paints over the body)"
        case documentViewShorterThanViewport = "document view height is less than the clip view's height"
        case textStorageImplausiblyShortForRowCount = "text storage is too short to hold even one character per row"
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
        // W3's actual root cause. A gutter that filled more than its own rule
        // thickness painted over something — on the sighting this was written
        // from, 880pt of fill from a 40pt-wide ruler, which is the entire
        // scroll view. `>`, not `>=`: filling exactly the gutter is the
        // healthy case, and this term must be silent for it.
        if m.gutterFillWidth > m.ruleThickness { reasons.append(.gutterFillWiderThanGutter) }
        // A document view shorter than the viewport showing it can only paint
        // part of what the ruler numbered. The 1pt tolerance is deliberate:
        // AppKit sizes the text view against the clip view to within rounding,
        // and a tripwire that fires on a healthy pane is worse than no
        // tripwire. `clipViewHeight > 0` keeps a mid-layout pane out of it.
        if m.clipViewHeight > 0, m.documentViewHeight + 1 < m.clipViewHeight {
            reasons.append(.documentViewShorterThanViewport)
        }
        // `rowCount` rows joined by newlines are always at least
        // `rowCount - 1` characters long, and exactly that only when every
        // single row is empty. A merely blank-line-heavy document is well
        // clear of this and must never trip it.
        if m.rowCount > 1, m.textStorageLength <= m.rowCount - 1 {
            reasons.append(.textStorageImplausiblyShortForRowCount)
        }
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
               "gutterFillWidth=\(m.gutterFillWidth) documentViewHeight=\(m.documentViewHeight) " +
               "clipViewHeight=\(m.clipViewHeight) textKitDowngraded=\(m.textKitDowngraded)"
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
        gutter fill width: \(m.gutterFillWidth)
        document view height: \(m.documentViewHeight)
        clip view height: \(m.clipViewHeight)
        TextKit 1 downgrade: \(m.textKitDowngraded)
        """
    }
}
