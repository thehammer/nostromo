import Foundation

/// Judges whether a split *actually* landed where it was asked to land, and
/// what the caller should do about it
/// (fix/detail-region-split-collapse — D1/D2/D3).
///
/// `RatioSolver` answers "where should the dividers go"; this answers the
/// question nobody was asking before: "did they go there?". The defect it
/// exists for is that `NSSplitView.setPosition(_:ofDividerAt:)` is free to
/// clamp what it is given and says nothing about having done so, and
/// `DynamicFocusView.applyRatios` reported `true` regardless. On a detail
/// region torn down and re-inserted during a PR pickup, a requested
/// `[0.5, 0.5]` landed at `0.9807 / 0.0193` — a 34pt-wide detail region in a
/// 1760pt split whose correct share is 879.5pt each — and was certified as
/// applied, so `RatioSplitView.layout()` cleared `desiredRatios` and never
/// retried.
///
/// `import Foundation` only, no AppKit — dual Sources/TestSources
/// membership, the same host-lessly-testable pattern as `RatioSolver.swift`
/// and `PaneRenderPlan.swift`. The view measures; this type only judges.
enum RatioApplicationAudit {

    /// Per-child tolerance in ratio units (percentage points / 100).
    ///
    /// Chosen against measurements, not intuition, from both ends.
    ///
    /// **The failures it must catch.** The collapse is `0.9807 / 0.0193`
    /// against a requested `0.5 / 0.5` — **48.1 percentage points** out on
    /// each child. The earlier capture of the same defect, `0.978 / 0.022`,
    /// is 47.8 points out. Any genuinely unusable region is in this range:
    /// even a detail pane at 200pt of an 880pt share is 39 points out.
    ///
    /// **The noise it must tolerate.** `NSSplitView.setPosition` lands a
    /// roughly **constant ~44pt short** on the vertical split of the
    /// product's own layout, whatever ratio it is handed — measured at
    /// 50.9pt, 48.0pt and 41.7pt for requests of 0.6, 0.5 and 0.3 in the
    /// same 810pt split. This predates the fix: `origin/main` produces
    /// byte-identical geometry and simply never noticed, which is the whole
    /// reason this type exists. It is tracked separately
    /// (`.claude/bugs/open/2026-09-08-nssplitview-setposition-lands-a-constant-44pt-short-on-the-vertical-split.md`)
    /// and is not what this fix is about.
    ///
    /// A **constant** absolute error is a *variable* ratio error, which is
    /// the trap here: 44pt is 5.4 points of an 810pt split (the launch
    /// smoke window, the smallest the app ever lays out in) but only 2.4 of
    /// an 1810pt one and 2.2 of a full-height display. A tolerance of 5
    /// points is therefore satisfiable on a real display and *unsatisfiable*
    /// in the smoke window — verified against three different requested
    /// ratios, none of which could clear it.
    ///
    /// Ten points sits an order of magnitude below every real failure and
    /// ~1.6x above the worst observed noise, with nothing measured anywhere
    /// in between. Tighten it when the 44pt offset is fixed; do not tighten
    /// it below ~7 until then, or the launch smoke check goes permanently
    /// INCONCLUSIVE.
    static let defaultTolerance: Double = 0.10

    /// How much a child's achieved share must move between two layout
    /// passes to count as "the layout is still settling" rather than "the
    /// same result twice" (D2).
    ///
    /// A tenth of a percentage point. Large enough to absorb the
    /// floating-point noise of dividing pixel extents by their sum, small
    /// enough that any real movement — the smallest useful step is a whole
    /// point — reads as movement. This is deliberately *not* a tolerance on
    /// correctness; it only decides whether to keep trying.
    static let convergenceEpsilon: Double = 0.001

    /// The `worstDelta` reported for a comparison that could not be made at
    /// all (see `outcome`). One whole unit is the largest a per-child delta
    /// can ever be, so it reads correctly in a log line and can never be
    /// mistaken for a near miss.
    private static let unverifiableDelta: Double = 1.0

    /// How far the achieved split is from the requested one.
    enum Outcome: Equatable {
        case applied
        case missed(worstDelta: Double)
    }

    /// Compare a requested ratio set against what the split actually
    /// achieved (`DynamicFocusView.currentRatios(for:)`).
    ///
    /// The comparison is **per child, not aggregate**. A mean or a sum
    /// would let one collapsed child hide behind its well-placed siblings,
    /// which is precisely the shape of this bug: an 879pt pane and a 34pt
    /// pane average out to something unremarkable.
    ///
    /// The tolerance boundary is inclusive — a delta exactly equal to
    /// `tolerance` is applied, strictly greater is a miss.
    ///
    /// A shape that cannot be compared (mismatched child counts, or no
    /// children at all) is **never** `.applied`. There is no evidence the
    /// ratios were applied, and reporting "no evidence" as "applied" is the
    /// original defect in miniature. The caller retrying is harmless:
    /// `RatioSplitView.layout()` only audits a split that already has a
    /// real size and real children.
    static func outcome(requested: [Double],
                        achieved: [Double],
                        tolerance: Double = defaultTolerance) -> Outcome {
        guard !requested.isEmpty, requested.count == achieved.count else {
            return .missed(worstDelta: unverifiableDelta)
        }
        let worst = zip(requested, achieved).map { abs($0 - $1) }.max() ?? 0
        return worst <= tolerance ? .applied : .missed(worstDelta: worst)
    }

    /// What `RatioSplitView.layout()` should do next.
    enum Progress: Equatable {
        /// The split landed within tolerance. Stop.
        case applied
        /// It did not land, but the layout is still moving. Try again on
        /// the next pass.
        case retry
        /// It did not land, and this pass achieved the same thing the last
        /// one did — the layout has settled somewhere other than where it
        /// was asked to. Stop, and say so once.
        case converged(worstDelta: Double)
    }

    /// The D2 anti-spin rule.
    ///
    /// A split whose children genuinely cannot reach the requested ratio
    /// (a real minimum-width floor) would otherwise re-apply on every
    /// layout pass forever. The stop condition is **two consecutive passes
    /// achieving the same out-of-tolerance result** — that is "the layout
    /// has converged somewhere else", which is a different fact from "not
    /// settled yet".
    ///
    /// Deliberately *not* an attempt counter. A window resize legitimately
    /// drives many layout passes, and a fixed cap would silently
    /// reintroduce the collapsed-region bug at whatever window size needed
    /// more passes than the cap allowed.
    ///
    /// The tolerance check runs **before** the sameness check: a pass that
    /// landed is a success whatever the history. Reversing that order would
    /// make a recovering split give up on the very pass it succeeded on.
    static func progress(requested: [Double],
                         achieved: [Double],
                         previousAchieved: [Double]?,
                         tolerance: Double = defaultTolerance) -> Progress {
        guard case .missed(let worst) = outcome(
            requested: requested, achieved: achieved, tolerance: tolerance
        ) else {
            return .applied
        }
        guard let previous = previousAchieved, isSettled(achieved, previous) else {
            return .retry
        }
        return .converged(worstDelta: worst)
    }

    /// Whether two consecutive passes achieved the same thing. Sameness is
    /// all-children-agree: one child still moving means the split still is.
    /// A change in child count is movement too — a tabs region gaining a
    /// child mid-flight is not "the same result twice".
    private static func isSettled(_ achieved: [Double], _ previous: [Double]) -> Bool {
        guard achieved.count == previous.count else { return false }
        return zip(achieved, previous).allSatisfy { abs($0 - $1) <= convergenceEpsilon }
    }
}
