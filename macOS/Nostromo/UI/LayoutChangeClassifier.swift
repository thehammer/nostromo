import Foundation

/// How an incoming `FocusLayoutModel.tree` differs from what's currently
/// rendered by `DynamicFocusView` (W1 — curated-agent-views).
///
/// Replaces the old `paneIds`-array comparison in
/// `DynamicFocusView.handleLayoutUpdate`, which classified any tree with the
/// same pane ids in the same order as "content-only" — even when a `Split`
/// changed only its `direction` or `ratios` (silently dropping the agent's
/// layout intent), and even when opening/closing/switching a tab changed the
/// id set (wrongly triggering a full `renderLayout`, which wipes every
/// operator-dragged split ratio via `clearSavedRatios`).
///
/// `import Foundation` only, no AppKit — so it can be exercised in the
/// host-less `NostromoTests` logic bundle via dual Sources/TestSources
/// membership (see `TurnHeightEstimator.swift` for the established pattern).
enum LayoutChange: Equatable {
    /// The trees are exactly equal — no work is implied by the tree itself
    /// (a spurious re-publish, or a push that only ever touched content,
    /// which the tree never carries).
    case identical
    /// The trees differ, but not in any way this classifier tracks: same
    /// split topology everywhere, same tabs membership/active everywhere.
    /// Handled identically to `.identical` by the renderer — content-only.
    ///
    /// In practice this case is close to unreachable today: `PaneTree` is
    /// `Equatable` over exactly the fields this classifier compares (split
    /// shape/ratios, leaf pane ids, tabs membership/labels/active), so two
    /// trees indistinguishable by this walk are also `==` and therefore
    /// caught by `.identical` first. It's kept as its own case — rather than
    /// folded into `.identical` — as the deliberate landing spot for a future
    /// `PaneTree` field the daemon might add that this classifier doesn't
    /// (yet) need to key its structural decision on.
    case contentOnly
    /// One or more tabs nodes changed only which child is `active`, at the
    /// given root-relative paths. No teardown: flip visibility and the tab
    /// strip's selection.
    case activeTabOnly(paths: [String])
    /// One or more tabs nodes' `children`/`labels` changed, and the split
    /// topology did not, at the given root-relative paths. Rebuild only
    /// those tabs containers — do NOT clear saved split ratios.
    case tabMembership(paths: [String])
    /// The "split signature" changed: the set of split node paths, or any
    /// split's direction, child count, or ratios — or a non-tabs leaf's pane
    /// id changed at a fixed tree position. Full rebuild; the only case that
    /// clears saved split ratios.
    case splitTopology
}

enum LayoutChangeClassifier {

    /// Classify the change from `old` to `new`. `old`/`new` use the
    /// root-relative dotted path convention `"root"`, `"root.0"`,
    /// `"root.0.1"`, … for split children and `"root.tab0"`, … for tabs
    /// children, matching `DynamicFocusView.buildView`'s own path scheme
    /// closely enough to be useful for logging even though the exact string
    /// isn't otherwise interpreted.
    static func classify(old: PaneTree, new: PaneTree) -> LayoutChange {
        if old == new {
            return .identical
        }

        if splitSignature(old, path: "root") != splitSignature(new, path: "root")
            || nonTabsLeafIdentity(old, path: "root") != nonTabsLeafIdentity(new, path: "root")
        {
            return .splitTopology
        }

        var membershipPaths: [String] = []
        var activePaths: [String] = []
        collectTabsDiffs(old, new, path: "root", membership: &membershipPaths, active: &activePaths)

        if !membershipPaths.isEmpty {
            return .tabMembership(paths: membershipPaths)
        }
        if !activePaths.isEmpty {
            return .activeTabOnly(paths: activePaths)
        }
        return .contentOnly
    }

    // MARK: - Split signature

    /// One `Split` node's shape, keyed by its structural path. Tabs nodes
    /// contribute nothing of their own here (their membership/active state
    /// is deliberately elided from "the split signature") but are still
    /// walked, so a split nested inside a tab child is still tracked.
    private struct SplitSig: Equatable {
        let path: String
        let direction: SplitDirection
        let childCount: Int
        let ratios: [Double]
    }

    private static func splitSignature(_ node: PaneTree, path: String) -> [SplitSig] {
        switch node {
        case .leaf:
            return []
        case .split(let direction, let children, let ratios):
            var sigs = [SplitSig(path: path, direction: direction, childCount: children.count, ratios: ratios)]
            for (i, child) in children.enumerated() {
                sigs += splitSignature(child, path: "\(path).\(i)")
            }
            return sigs
        case .tabs(let children, _, _):
            var sigs: [SplitSig] = []
            for (i, child) in children.enumerated() {
                sigs += splitSignature(child, path: "\(path).tab\(i)")
            }
            return sigs
        }
    }

    // MARK: - Non-tabs leaf identity

    /// `path -> paneId` for every leaf reached WITHOUT passing through a
    /// tabs node. A leaf swapped for a different pane id at a fixed non-tabs
    /// position is a real structural change the split signature alone
    /// doesn't capture (it tracks `Split` shape, not what's inside a leaf).
    private static func nonTabsLeafIdentity(_ node: PaneTree, path: String) -> [String: String] {
        switch node {
        case .leaf(let paneId):
            return [path: paneId]
        case .split(_, let children, _):
            var out: [String: String] = [:]
            for (i, child) in children.enumerated() {
                out.merge(nonTabsLeafIdentity(child, path: "\(path).\(i)")) { existing, _ in existing }
            }
            return out
        case .tabs:
            return [:]
        }
    }

    // MARK: - Tabs diffs

    /// Walk `old`/`new` in lockstep (only reachable once the split signature
    /// and non-tabs leaf identities already match — see `classify`) and
    /// collect the paths of every tabs node whose membership (`children`'s
    /// pane ids or `labels`) changed, and separately every tabs node whose
    /// `active` index changed while membership stayed the same.
    private static func collectTabsDiffs(
        _ old: PaneTree, _ new: PaneTree, path: String,
        membership: inout [String], active: inout [String]
    ) {
        switch (old, new) {
        case (.split(_, let oldChildren, _), .split(_, let newChildren, _)):
            for i in 0..<min(oldChildren.count, newChildren.count) {
                collectTabsDiffs(oldChildren[i], newChildren[i], path: "\(path).\(i)", membership: &membership, active: &active)
            }
        case (.tabs(let oldChildren, let oldLabels, let oldActive), .tabs(let newChildren, let newLabels, let newActive)):
            let oldIds = oldChildren.map(\.paneIds)
            let newIds = newChildren.map(\.paneIds)
            if oldIds != newIds || oldLabels != newLabels {
                membership.append(path)
            } else if oldActive != newActive {
                active.append(path)
            }
            for i in 0..<min(oldChildren.count, newChildren.count) {
                collectTabsDiffs(oldChildren[i], newChildren[i], path: "\(path).tab\(i)", membership: &membership, active: &active)
            }
        default:
            // Leaf/Leaf (nothing to collect) or a kind mismatch that
            // `classify` should already have routed to `.splitTopology`
            // before ever reaching here.
            break
        }
    }
}
