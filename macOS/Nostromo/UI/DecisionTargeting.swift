import Foundation

// MARK: - Decision popup targeting
//
// A decision request is presented on exactly ONE window. This file is the pure
// rule for picking it: AppKit-free so it can be table-tested without windows.
//
// Why one window (and not every window): presenting on every display brought
// Nostromo forward on screens the operator was working on and switched their
// focus. Why not just "the key window": a single blindly-picked window once put
// the sheet on a Space nobody was looking at and the request was effectively
// lost (live report, 2026-10-06). So the choice is by what the operator can SEE,
// and the sidebar attention indicator covers the case where the sheet ended up
// on a window showing some other focus.

/// Which rung of the targeting ladder a window sits on for a given request.
/// Lower raw value == better.
enum DecisionTargetTier: Int, Comparable {
    /// A visible window already showing the asking focus.
    case askingFocus = 1
    /// A visible window showing some other focus.
    case otherFocus  = 2
    /// No window is visible anywhere (app hidden, other Spaces): any window, so
    /// the request exists when the operator returns.
    case fallback    = 3

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Whether an operator can actually see a window right now: on the active Space,
/// not occluded (covers a hidden app), not miniaturized. The pure part of
/// `NostromoWindow.isVisibleNow`, split out so it can be tested without AppKit windows.
func decisionWindowIsVisible(onActiveSpace: Bool, occlusionVisible: Bool, isMiniaturized: Bool) -> Bool {
    onActiveSpace && occlusionVisible && !isMiniaturized
}

/// What the targeting rule needs to know about one window.
struct DecisionWindowInfo<ID: Hashable> {
    let id: ID
    /// On the active Space, not occluded, not miniaturized.
    let isVisible: Bool
    let isKey: Bool
    /// Lower == nearer the front / more recently active.
    let order: Int
    /// The `sessionTag` of the focus this window is currently displaying.
    let activeFocusTag: String?
}

struct DecisionTarget<ID: Hashable> {
    let id: ID
    let tier: DecisionTargetTier
}

/// The tier `window` occupies for a request from focus `requestTag`.
func decisionTier<ID: Hashable>(of window: DecisionWindowInfo<ID>, requestTag: String) -> DecisionTargetTier {
    guard window.isVisible else { return .fallback }
    return window.activeFocusTag == requestTag ? .askingFocus : .otherFocus
}

/// Zero or one window to present the request on: the best tier present, and
/// within it the key window, then the lowest `order`, then the first listed.
/// Empty only when there are no windows at all.
func selectDecisionTargets<ID: Hashable>(
    windows: [DecisionWindowInfo<ID>], requestTag: String
) -> [DecisionTarget<ID>] {
    let ranked = windows.enumerated().map { index, window in
        (window: window, index: index, tier: decisionTier(of: window, requestTag: requestTag))
    }
    let best = ranked.min { lhs, rhs in
        if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
        if lhs.window.isKey != rhs.window.isKey { return lhs.window.isKey }
        if lhs.window.order != rhs.window.order { return lhs.window.order < rhs.window.order }
        return lhs.index < rhs.index
    }
    return best.map { [DecisionTarget(id: $0.window.id, tier: $0.tier)] } ?? []
}
