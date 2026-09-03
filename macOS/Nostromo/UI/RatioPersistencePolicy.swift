import Foundation

/// Decides whether a set of split ratios reflects a deliberate operator
/// choice worth persisting to `UserDefaults`, as opposed to a value produced
/// by our own programmatic layout application or a transient/degenerate
/// resize.
///
/// Extracted so the write-guard is a single pure, testable decision. Before
/// this existed, `DynamicFocusView.makeSplitView`'s resize observer persisted
/// *every* `NSSplitView.didResizeSubviewsNotification` unconditionally,
/// including: the transient layout pass while a newly created region is
/// still being inserted (its new child has no real width yet); this file's
/// own `applyRatios`/`RatioSplitView.layout()` programmatically setting
/// divider positions; and plain window resize/fullscreen/display-
/// reconfiguration churn. None of those is an operator dragging a divider,
/// but all of them got written to disk as if they were — and, once written,
/// a corrupt value like `[0.977, 0.022]` was authoritative forever (see
/// fix-collapsed-split-ratio-persistence).
///
/// `Foundation` only — dual Sources/TestSources membership, same pattern as
/// `RatioSolver.swift`/`LayoutChangeClassifier.swift`.
enum RatioPersistencePolicy {

    /// The smallest share a pane may hold and still be considered a
    /// deliberate operator choice. Below this a pane has no grabbable
    /// divider edge and effectively no visible content, so it cannot be
    /// undone by dragging in the UI. "Reset Layout" clears the *whole* saved
    /// set rather than repairing one bad value, so persisting a share this
    /// small would strand the operator in a layout they can't escape without
    /// `defaults delete` — we refuse to write it instead.
    static let minimumShare = 0.05

    /// Whether `ratios` has a shape that could ever represent a deliberate,
    /// usable split: more than one share (a single child has no divider to
    /// drag, so there is no "choice" here at all), and every share at least
    /// `minimumShare`.
    ///
    /// This is the one check shared by two different questions asked at two
    /// different times: `shouldPersist` below asks it of a *fresh* resize,
    /// to decide whether to write it; `DynamicFocusView.makeSplitView` asks
    /// it of a value already *read back* from disk, to decide whether to
    /// trust it, before the split has been given a real size to check a
    /// `total` against at all. Neither of those callers' other concerns —
    /// `isProgrammatic`, `total` — has any bearing on shape, so this takes
    /// neither parameter.
    static func isWellFormed(ratios: [Double]) -> Bool {
        ratios.count > 1 && ratios.allSatisfy { $0 >= minimumShare }
    }

    /// Whether `ratios` should be written to disk as the operator's chosen
    /// split.
    ///
    /// Refuses when:
    /// - `isUserDrag` is false — this resize did not happen while the
    ///   operator's mouse button was down on a divider. A window resize,
    ///   fullscreen transition, or display reconfiguration fires the exact
    ///   same `NSSplitView.didResizeSubviewsNotification` a divider drag
    ///   does, and none of them is an operator choice; `isUserDrag` is the
    ///   one signal that actually distinguishes "the operator grabbed a
    ///   divider" from all of those (fix-collapsed-split-ratio-persistence,
    ///   second-pass finding: the original signature had no way to tell
    ///   them apart at all, so a window resize persisted a ratio just like a
    ///   drag did).
    /// - `isProgrammatic` is true — this resize was caused by our own code
    ///   applying ratios, not an operator drag. Kept as an explicit,
    ///   independent guard even though a programmatic apply and a user drag
    ///   should never overlap in practice — belt-and-suspenders, not the
    ///   primary signal.
    /// - `total` is not a plausible container size (`<= 0`) — no real
    ///   geometry to have chosen a ratio from.
    /// - `ratios` isn't `isWellFormed` (see above).
    static func shouldPersist(ratios: [Double], total: Double, isProgrammatic: Bool, isUserDrag: Bool) -> Bool {
        guard isUserDrag else { return false }
        guard !isProgrammatic else { return false }
        guard total > 0 else { return false }
        return isWellFormed(ratios: ratios)
    }
}
