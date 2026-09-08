import Foundation

/// Judges whether a pane that has been given content is actually drawable —
/// the observable half of the invariant behind the (unreproduced)
/// queue-pane-blank-on-first-paint report
/// (`.claude/bugs/open/2026-08-14-queue-pane-renders-blank-on-the-first-pane-content-push-after-a-fresh-session-app-launch.md`
/// in the primary repo).
///
/// The invariant: a pane that holds non-nil, non-`loading` content, is in a
/// window, and has completed a layout pass, must have a drawable size
/// (`bounds.width > 0` and `bounds.height > 0`). Every term is observable
/// inside `PaneContentNSView` itself, which is why this is measured from the
/// consumer side (`AppKit`, in `DynamicFocusView.swift`) rather than from
/// inside the split-ratio machinery that happens to be the leading suspect —
/// that keeps this catching *any* cause of a non-drawable pane, not only the
/// one currently suspected, and keeps it off `applyRatios`'/`currentRatios`'
/// change surface entirely.
///
/// `import Foundation` only, no AppKit — so it can be exercised in the
/// host-less `NostromoTests` logic bundle via dual Sources/TestSources
/// membership (see `PaneRenderPlan.swift` for the established pattern this
/// follows). The view does the measuring; this type only judges.
enum PaneFirstPaintAudit {

    /// What `PaneContentNSView.layout()` can observe about itself in the
    /// moment — content presence/kind is intentionally reduced to a `Bool`
    /// (`hasContent`) rather than carried as the actual `PaneContentWire`,
    /// so nothing in this type can ever be tempted to log pane content.
    struct Measurements: Equatable {
        let paneId: String
        let hasContent: Bool
        let isLoading: Bool
        let boundsWidth: Double
        let boundsHeight: Double
        let hasWindow: Bool
        let layoutPassCount: Int
    }

    /// A failing dimension for `.notDrawable`: no drawable size at all.
    /// `rawValue` is used verbatim in `summary(of:)`.
    enum NotDrawableReason: String, Equatable {
        case zeroWidth
        case zeroHeight
    }

    /// A failing dimension for `.tooSmall`: a real, non-zero size that is
    /// still too small to be usable (fix/detail-region-split-collapse — D6).
    /// `rawValue` is used verbatim in `summary(of:)`.
    ///
    /// Kept as its own type rather than sharing `NotDrawableReason` — the
    /// two verdicts never overlap (see `verdict(_:)`), so a shared type
    /// would force `shouldReport`'s `.tooSmall` switch to handle
    /// `.zeroWidth`/`.zeroHeight` cases that can never actually occur there.
    enum SmallReason: String, Equatable {
        case tooNarrow
        case tooShort
    }

    enum Verdict: Equatable {
        case healthy
        /// Zero (or negative) on at least one axis — unchanged meaning.
        case notDrawable(reasons: [NotDrawableReason])
        /// Non-zero on both axes but below `minimumUsableExtent` on at
        /// least one — the signature of a split whose `setPosition` was
        /// clamped: measured live at 34pt wide where 879.5pt was correct.
        case tooSmall(reasons: [SmallReason])
    }

    /// Below this many points on an axis, a pane that has content and has
    /// been laid out in a window is not showing the operator anything
    /// usable. Chosen against the fix/detail-region-split-collapse
    /// measurements: the collapsed detail region was 34pt wide, a healthy
    /// one 879.5pt — so the threshold is an order of magnitude above the
    /// failure and an order of magnitude below the healthy case, which is
    /// the margin a tripwire needs to never fire on a genuinely narrow but
    /// deliberate pane.
    static let minimumUsableExtent: Double = 120

    /// `.notDrawable` only when **all** of these hold — each precondition
    /// exists to keep the wire quiet during a normal, healthy pane
    /// lifecycle:
    ///   - `hasContent`: a pane before its first push has nothing to draw by
    ///     design (renders "waiting for content…").
    ///   - `!isLoading`: a transient `Loading` frame is expected to have
    ///     nothing to draw yet.
    ///   - `hasWindow`: a pane in an unselected tab, or a window mid
    ///     construction, has no drawable size by design.
    ///   - `layoutPassCount > 0`: before the first layout pass there is no
    ///     evidence either way.
    /// Only then does a non-positive width or height actually mean
    /// something, and even then only the failing dimension(s) are named —
    /// width checked before height, deterministically.
    ///
    /// `.tooSmall` (D6) is judged under the **same** four preconditions and
    /// only once zero has been ruled out: a pane with no drawable size at
    /// all is `.notDrawable`, never `.tooSmall`, so the two populations
    /// never overlap and the original verdict keeps its exact meaning.
    static func verdict(_ m: Measurements) -> Verdict {
        guard m.hasContent, !m.isLoading, m.hasWindow, m.layoutPassCount > 0 else {
            return .healthy
        }
        var zeroReasons: [NotDrawableReason] = []
        if m.boundsWidth <= 0 { zeroReasons.append(.zeroWidth) }
        if m.boundsHeight <= 0 { zeroReasons.append(.zeroHeight) }
        guard zeroReasons.isEmpty else { return .notDrawable(reasons: zeroReasons) }

        var smallReasons: [SmallReason] = []
        if m.boundsWidth < minimumUsableExtent { smallReasons.append(.tooNarrow) }
        if m.boundsHeight < minimumUsableExtent { smallReasons.append(.tooShort) }
        return smallReasons.isEmpty ? .healthy : .tooSmall(reasons: smallReasons)
    }

    /// Whether an unhealthy verdict is worth *reporting* yet — the
    /// sampling rule that keeps D6 off healthy panes.
    ///
    /// `.notDrawable` reports immediately; that behaviour is unchanged.
    ///
    /// `.tooSmall` waits for the offending axis to **stop moving**, because
    /// a perfectly healthy pane legitimately passes through small extents
    /// on its way to a real size. Measured on the reproduction bench for
    /// this fix, all on panes that ended up entirely healthy:
    ///
    /// | pane     | pass | measured    | settled at   |
    /// |----------|------|-------------|--------------|
    /// | queue    | 1    | 639.5 x 36  | 639.5 x 485.5|
    /// | queue    | 6    | 639.5 x 56  | 639.5 x 485.5|
    /// | detail.0 | 1    | 48 x 10     | 639.5 x 459.5|
    ///
    /// Those transients overlap the real failure's magnitude (34pt) closely
    /// enough that **no threshold can separate them** — 48 is wider than
    /// 34. The discriminator is not how small, but whether it stays that
    /// way.
    ///
    /// "Stays that way" is checked **per offending axis** — only the axes
    /// actually below the threshold have to hold still, and an axis that is
    /// a healthy size may move freely. A collapsed split pins one axis while
    /// the other is still settling: the bench's genuinely-collapsed detail
    /// panes measured 44 x 434.5 then 44 x 385.5 — width pinned at its
    /// floor, height still arriving. Comparing whole measurements instead
    /// would have missed that, and a pane that settles and then simply never
    /// lays out again would never be reported at all.
    ///
    /// When *both* axes are offending, **both** must have settled. This is
    /// the deliberately conservative side of a real trade-off: it can
    /// silence a genuine single-axis collapse that happens to sit in a
    /// window short enough for the other axis to be sub-threshold too and
    /// still moving (44 x 100 → 44 x 90 reports nothing). Requiring only
    /// *one* offending axis to have settled would catch that, at the cost of
    /// firing on a pane that is briefly small on both axes on its way to
    /// being fine — which is precisely the 48 x 10 transient in the table
    /// above. Silence on a healthy pane is the error this file has always
    /// chosen, and the gap is not load-bearing: a collapsed split is caught
    /// independently by `RatioApplicationAudit`'s own `.error` line and by
    /// the launch smoke's `ratios-claimed-honestly` gate, neither of which
    /// looks at pane geometry at all.
    ///
    /// This is the file's own standing rule applied to a new term: a
    /// tripwire that fires on a healthy pane is worse than no tripwire.
    static func shouldReport(_ m: Measurements, previous: Measurements?) -> Bool {
        switch verdict(m) {
        case .healthy:
            return false
        case .notDrawable:
            return true
        case .tooSmall(let reasons):
            guard let previous else { return false }
            return reasons.allSatisfy { reason in
                switch reason {
                case .tooNarrow: return m.boundsWidth == previous.boundsWidth
                case .tooShort:  return m.boundsHeight == previous.boundsHeight
                }
            }
        }
    }

    /// The rate-limit identity of a violation: everything `summary(of:)`
    /// carries **except** the layout-pass counter.
    ///
    /// `summary(of:)` is what gets logged, and it names `layoutPasses` —
    /// which increments on every single pass. Using the summary itself as
    /// the rate-limit key therefore never deduplicated anything: a pane
    /// stuck in one bad state produced a distinct string every pass and
    /// logged every pass, exactly the behaviour the limiter's own doc
    /// comment says it prevents. Harmless while the only verdict was
    /// `.notDrawable` (a zero-size pane usually stops laying out); not
    /// harmless now that `.tooSmall` fires on a pane that is very much
    /// alive and relaying out — observed flooding the log thousands of
    /// times in one run.
    static func violationKey(of m: Measurements) -> String {
        "pane=\(m.paneId) hasContent=\(m.hasContent) loading=\(m.isLoading) " +
        "hasWindow=\(m.hasWindow) bounds=\(m.boundsWidth)x\(m.boundsHeight) " +
        "verdict=\(verdictText(of: m))"
    }

    /// Deterministic single-line summary, counts/ids/kinds/geometry only —
    /// never pane content. `PaneContentNSView`'s rate limiter (D3) compares
    /// this string across layout passes to decide whether a violation is
    /// new, so equal `Measurements` MUST produce an equal string here.
    static func summary(of m: Measurements) -> String {
        "pane=\(m.paneId) hasContent=\(m.hasContent) loading=\(m.isLoading) " +
        "hasWindow=\(m.hasWindow) layoutPasses=\(m.layoutPassCount) " +
        "bounds=\(m.boundsWidth)x\(m.boundsHeight) verdict=\(verdictText(of: m))"
    }

    /// The `verdict=` field shared by `summary(of:)` and `violationKey(of:)`,
    /// so the two can never disagree about what a measurement was judged to
    /// be.
    private static func verdictText(of m: Measurements) -> String {
        switch verdict(m) {
        case .healthy:
            return "healthy"
        case .notDrawable(let reasons):
            return "notDrawable(\(reasons.map(\.rawValue).joined(separator: ",")))"
        case .tooSmall(let reasons):
            return "tooSmall(\(reasons.map(\.rawValue).joined(separator: ",")))"
        }
    }
}
