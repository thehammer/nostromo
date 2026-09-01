import Foundation

/// Pure arithmetic for translating relative split ratios into absolute
/// `NSSplitView` divider positions (fix/detail-region-content-not-rendering
/// — D3). Extracted out of what used to be `DynamicFocusView.applyRatios`'s
/// inline calculation so it's exercisable without a real window/split view.
///
/// `RatioSplitView.layout()` is the only caller: it asks for divider
/// positions on every layout pass until this returns non-nil, then stops.
/// Refusing to answer (returning `nil`) rather than producing some
/// plausible-looking-but-wrong positions is what lets that caller tell
/// "the split has no real size yet, try again next layout pass" apart from
/// "here are the positions, you're done" — collapsing that distinction is
/// exactly how split ratios used to go silently unapplied forever on a
/// split that had zero size the one time a one-shot `DispatchQueue.main.async`
/// callback happened to run.
///
/// `import Foundation` only, no AppKit — dual Sources/TestSources
/// membership, same pattern as `LayoutChangeClassifier.swift`.
enum RatioSolver {

    /// `subviewCount` children lay out proportionally to `ratios` inside a
    /// container of size `total`, with `subviewCount - 1` dividers each
    /// `dividerThickness` thick between them. Returns the absolute position
    /// of each divider (`subviewCount - 1` of them, in order, measured from
    /// the start of the container) — or `nil` if the inputs can't produce a
    /// meaningful answer:
    ///
    /// - `total <= 0` — no real size yet.
    /// - `subviewCount <= 0` — nothing to lay out.
    /// - `ratios.count != subviewCount` — a count mismatch against the
    ///   actual number of subviews.
    /// - `ratios` don't sum to ~1.0 (tolerance `0.01`).
    static func dividerPositions(
        ratios: [Double],
        total: Double,
        dividerThickness: Double,
        subviewCount: Int
    ) -> [Double]? {
        guard total > 0, subviewCount > 0, ratios.count == subviewCount else { return nil }
        let sum = ratios.reduce(0, +)
        guard abs(sum - 1.0) < 0.01 else { return nil }

        let dividerTotal = dividerThickness * Double(subviewCount - 1)
        let usable = total - dividerTotal

        var positions: [Double] = []
        var offset: Double = 0
        for i in 0..<subviewCount {
            let size = usable * ratios[i]
            if i < subviewCount - 1 {
                positions.append(offset + size)
            }
            offset += size + dividerThickness
        }
        return positions
    }
}
