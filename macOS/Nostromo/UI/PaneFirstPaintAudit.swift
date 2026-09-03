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

    /// One failing dimension. `rawValue` is used verbatim in `summary(of:)`.
    enum Reason: String, Equatable {
        case zeroWidth
        case zeroHeight
    }

    enum Verdict: Equatable {
        case healthy
        case notDrawable(reasons: [Reason])
    }

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
    static func verdict(_ m: Measurements) -> Verdict {
        guard m.hasContent, !m.isLoading, m.hasWindow, m.layoutPassCount > 0 else {
            return .healthy
        }
        var reasons: [Reason] = []
        if m.boundsWidth <= 0 { reasons.append(.zeroWidth) }
        if m.boundsHeight <= 0 { reasons.append(.zeroHeight) }
        return reasons.isEmpty ? .healthy : .notDrawable(reasons: reasons)
    }

    /// Deterministic single-line summary, counts/ids/kinds/geometry only —
    /// never pane content. `PaneContentNSView`'s rate limiter (D3) compares
    /// this string across layout passes to decide whether a violation is
    /// new, so equal `Measurements` MUST produce an equal string here.
    static func summary(of m: Measurements) -> String {
        let verdictText: String
        switch verdict(m) {
        case .healthy:
            verdictText = "healthy"
        case .notDrawable(let reasons):
            verdictText = "notDrawable(\(reasons.map(\.rawValue).joined(separator: ",")))"
        }
        return "pane=\(m.paneId) hasContent=\(m.hasContent) loading=\(m.isLoading) " +
               "hasWindow=\(m.hasWindow) layoutPasses=\(m.layoutPassCount) " +
               "bounds=\(m.boundsWidth)x\(m.boundsHeight) verdict=\(verdictText)"
    }
}
