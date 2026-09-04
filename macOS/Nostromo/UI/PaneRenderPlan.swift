import Foundation

/// Exactly what a rendered `PaneTree` must contain, by structural path
/// (fix/detail-region-content-not-rendering — D1).
///
/// `DynamicFocusView` builds three separate pieces of live bookkeeping while
/// it walks a `PaneTree` — `leafViews` (every leaf's content view, including
/// tab-hosted ones), the set of split-node paths an incremental repair keys
/// off of, and the `TabRegionView` metadata a tabs update targets — and the
/// bug this file fixes is that those three can silently fall out of step
/// with the tree the daemon actually sent: an incremental repair path
/// (`applyActiveTabOnly`/`applyTabMembership`/`replaceInPlace`) can fail
/// partway through while `renderedTree` still advances as though it fully
/// succeeded, so nothing ever notices the divergence.
///
/// `PaneRenderPlan` is the single, pure description of "what should exist,
/// and at what path" that `DynamicFocusView.reconcile` compares its actual
/// live state against, rebuilding from scratch the moment they disagree
/// rather than trusting bookkeeping that might already be wrong.
///
/// `import Foundation` only, no AppKit — so it can be exercised in the
/// host-less `NostromoTests` logic bundle via dual Sources/TestSources
/// membership (see `LayoutChangeClassifier.swift` for the established
/// pattern this follows).
struct PaneRenderPlan: Equatable {

    /// One `PaneTree.tabs` node's expected shape.
    struct TabsNode: Equatable {
        let path: String
        let paneIds: [String]
        let labels: [String]
        let activePaneId: String
    }

    /// path -> paneId, for every leaf in the tree — including a tabs node's
    /// children, since `DynamicFocusView.leafViews` holds every pane's raw
    /// content view whether or not it's hosted inside a `TabRegionView`.
    ///
    /// Keyed by path rather than by pane id on purpose: a `[paneId: path]`
    /// map would silently collapse two leaves that (erroneously) share a
    /// pane id into one entry. Keying by path can't lose either occurrence,
    /// which is what makes that violated invariant detectable at all rather
    /// than being quietly hidden the moment it happens.
    let leafPaths: [String: String]
    /// Root-relative dotted path of every `.split` node in the tree,
    /// depth-first, left to right.
    let splitPaths: [String]
    /// Every `.tabs` node's expected shape, depth-first, left to right —
    /// the same order `splitPaths` uses, so a reconciliation step walking
    /// both has one consistent traversal to reason about.
    let tabsNodes: [TabsNode]

    /// Every pane id this plan expects to be resident somewhere. A `Set`,
    /// so (unlike `leafPaths`) a duplicated pane id collapses here by
    /// design — this is the "how many distinct panes" view, not the
    /// "did we lose one" view.
    var paneIds: Set<String> { Set(leafPaths.values) }

    /// Walk `tree` and produce the plan it implies. Uses the same
    /// root-relative dotted path convention `LayoutChangeClassifier` and
    /// `DynamicFocusView.buildView` use: `"root"`, `"root.0"`, `"root.0.1"`,
    /// … for split children, `"root.tab0"`, … for tabs children.
    static func build(from tree: PaneTree) -> PaneRenderPlan {
        var leafPaths: [String: String] = [:]
        var splitPaths: [String] = []
        var tabsNodes: [TabsNode] = []
        walk(tree, path: "root", leafPaths: &leafPaths, splitPaths: &splitPaths, tabsNodes: &tabsNodes)
        return PaneRenderPlan(leafPaths: leafPaths, splitPaths: splitPaths, tabsNodes: tabsNodes)
    }

    private static func walk(
        _ node: PaneTree,
        path: String,
        leafPaths: inout [String: String],
        splitPaths: inout [String],
        tabsNodes: inout [TabsNode]
    ) {
        switch node {
        case .leaf(let paneId):
            leafPaths[path] = paneId

        case .split(_, let children, _):
            splitPaths.append(path)
            for (i, child) in children.enumerated() {
                walk(child, path: "\(path).\(i)", leafPaths: &leafPaths, splitPaths: &splitPaths, tabsNodes: &tabsNodes)
            }

        case .tabs(let children, let labels, let active):
            // Same fallback as DynamicFocusView.buildTabs
            // (`tabs.first?.paneId ?? ""`) and TabRegionView.init
            // (`tabs.first?.paneId ?? activePaneId`) — all three must agree
            // on what an out-of-bounds `active` index resolves to.
            let childPaneIds = children.map { $0.paneIds.first ?? "unknown" }
            let activePaneId = childPaneIds.indices.contains(active) ? childPaneIds[active] : (childPaneIds.first ?? "")
            tabsNodes.append(TabsNode(path: path, paneIds: childPaneIds, labels: labels, activePaneId: activePaneId))
            for (i, child) in children.enumerated() {
                walk(child, path: "\(path).tab\(i)", leafPaths: &leafPaths, splitPaths: &splitPaths, tabsNodes: &tabsNodes)
            }
        }
    }
}
