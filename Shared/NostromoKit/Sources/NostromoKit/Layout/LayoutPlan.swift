// NostromoKit — LayoutPlan.swift
//
// The iOS layout decision (W6 — ios-curated-view-parity, D2/D3): a PURE
// function of `(PaneTree, WidthClass)` and nothing else. No view hierarchy,
// no `GeometryReader`, no environment, no device, no orientation, no point
// threshold.
//
// This purity is not stylistic. The regular-width (iPad) presentation is the
// one part of this PRD nobody can check automatically — there is no iOS test
// target, no simulator in CI, and no iPad on the build machine — and the
// PRD's own risk section names it "the part most likely to be quietly
// half-working". Extracting the layout DECISION is the only form in which
// that decision is testable at all, so everything that can live here does,
// and `LayoutPlanTests` is this wedge's substantive deliverable. What is
// genuinely left over — observed on-screen proportions, the live rotation
// and multitasking-resize transitions, per-region unread legibility — is
// listed as device-only in `docs/ios-verification.md` rather than pretended
// about.
//
// import Foundation only — pure value types and pure functions, exercised by
// `make kit-test` with no simulator and no device.
import Foundation

// MARK: - LayoutPlan

/// What iOS should render for a focus, at a given width.
public enum LayoutPlan: Equatable {

    /// One surface at a time, one strip: the whole tree flattened. This is
    /// W5's compact presentation verbatim — the entries are exactly what
    /// `TabPlan.build(tree:content:)` returns, and `LayoutPlanTests` asserts
    /// that equality directly so a future edit cannot quietly fork the
    /// compact path while claiming to leave it alone.
    case singleRegion([TabPlanEntry])

    /// Real regions, in the daemon's directions, at the daemon's ratios.
    case regions(RegionNode)

    /// Every region in THIS plan that hosts panes, in walk order — the unit
    /// `FocusRegionState` is keyed by (frontmost pane, unread marks).
    ///
    /// Compact has exactly one region: the whole strip, at `RegionPath.root`.
    /// At regular width a `.tabbed` node reports the panes it hosts
    /// *directly* (tabs whose content is a plain leaf); a tab that itself
    /// contains a nested `split`/`tabs` is its own addressable region with
    /// its own strip and its own frontmost tab (D4), and is reported
    /// separately rather than folded into its parent's membership.
    public var regions: [RegionMembership] {
        switch self {
        case .singleRegion(let entries):
            return [RegionMembership(path: RegionPath.root, paneIds: entries.map(\.paneId))]
        case .regions(let node):
            var out: [RegionMembership] = []
            LayoutPlan.collectRegions(node, into: &out)
            return out
        }
    }

    private static func collectRegions(_ node: RegionNode, into out: inout [RegionMembership]) {
        switch node {
        case .bare(let path, let paneId):
            out.append(RegionMembership(path: path, paneIds: [paneId]))
        case .split(_, let children, _):
            // A split is pure arrangement — it hosts no panes of its own and
            // therefore holds no frontmost/unread state.
            for child in children { collectRegions(child, into: &out) }
        case .tabbed(let path, let tabs):
            var direct: [String] = []
            var nested: [RegionNode] = []
            for tab in tabs {
                if case .bare(_, let paneId) = tab.content {
                    direct.append(paneId)
                } else {
                    nested.append(tab.content)
                }
            }
            out.append(RegionMembership(path: path, paneIds: direct))
            for child in nested { collectRegions(child, into: &out) }
        }
    }
}

// MARK: - RegionNode

/// One node of the regular-width arrangement. Recursive, so nesting is real
/// nesting (D3): a `split` whose child is a `split` produces regions within
/// regions rather than a flattened row, and a `split` whose child is a `tabs`
/// node produces a region with its own strip. The obvious shortcut — walking
/// to depth one and treating everything below as a leaf — produces a
/// plausible-looking layout that silently loses panes, which is why
/// `LayoutPlanTests` asserts the SHAPE rather than the leaf count.
public indirect enum RegionNode: Equatable {

    /// Several regions side by side. `shares` is NOT the wire's `ratios`: it
    /// always has exactly one element per child, every element is strictly
    /// positive, and the elements sum to 1. Named `shares` rather than
    /// `ratios` precisely so the two can't be confused at a call site — the
    /// view divides screen space by these numbers and any other total blanks
    /// or overlaps a region. See `normalisedShares(ratios:childCount:)` for
    /// the rule that gets from one to the other.
    case split(direction: SplitDirection, children: [RegionNode], shares: [Double])

    /// A region with its own tab strip and its own frontmost tab. `path` is
    /// the `tabs` NODE's own region path — the key this region's
    /// `FocusRegionState` entries live under. Each tab carries its own
    /// child path.
    case tabbed(path: String, tabs: [RegionTab])

    /// A leaf with no chrome: a `split` child that is a plain leaf, or a
    /// whole tree that is a single `repl` leaf.
    case bare(path: String, paneId: String)
}

/// One tab of a `.tabbed` region.
public struct RegionTab: Equatable {

    /// This tab's strip entry — the same `TabPlanEntry` type the compact
    /// strip is built from, so `TabStripView` renders a region's strip and
    /// the compact strip with one code path. `tabIndex` is the position
    /// within THIS region's strip, and `regionPath` is this tab's own path
    /// (identical to the path the compact plan assigns the same node — the
    /// property that lets region state resolve across a width-class change).
    public let entry: TabPlanEntry

    /// What the tab shows: `.bare` in the ordinary leaf case, or a nested
    /// `.split`/`.tabbed` when the daemon nests structure inside a tab —
    /// a region within a tab.
    public let content: RegionNode

    public init(entry: TabPlanEntry, content: RegionNode) {
        self.entry = entry
        self.content = content
    }
}

/// A region and the panes it hosts, for keying `FocusRegionState`.
public struct RegionMembership: Equatable {
    public let path: String
    public let paneIds: [String]

    public init(path: String, paneIds: [String]) {
        self.path = path
        self.paneIds = paneIds
    }
}

// MARK: - The decision

/// Decide what iOS renders for `tree` at `width`. Pure — the same inputs
/// always produce the same plan, with no reference to a live view hierarchy.
///
/// `content` supplies each pane's current `PaneContentWire`, read only for
/// the tab-label fallback (`TabPlan.fallbackLabel`) and defaulted for callers
/// that have no pushed content yet. A label never differs between
/// presentations: the same node gets the same text at both widths.
public func layoutPlan(
    tree: PaneTree,
    width: WidthClass,
    content: [String: PaneContentWire] = [:]
) -> LayoutPlan {
    switch width {
    case .compact:
        // W5's flattening, unchanged and untouched. Called through rather
        // than reimplemented so the two can never drift.
        return .singleRegion(TabPlan.build(tree: tree, content: content))
    case .regular:
        return .regions(regionNode(tree, path: RegionPath.root, content: content))
    }
}

/// The regular-width walk. Region paths use `RegionPath`'s convention
/// verbatim, and — critically — are assigned by the same rule the compact
/// flattening uses, so a given node's path is identical in both plans.
private func regionNode(
    _ node: PaneTree,
    path: String,
    content: [String: PaneContentWire]
) -> RegionNode {
    switch node {
    case .leaf(let paneId):
        return .bare(path: path, paneId: paneId)

    case .split(let direction, let children, let ratios):
        let regions = children.enumerated().map { index, child in
            regionNode(child, path: RegionPath.splitChild(path, index), content: content)
        }
        return .split(
            direction: direction,
            children: regions,
            shares: normalisedShares(ratios: ratios, childCount: children.count)
        )

    case .tabs(let children, let labels, _):
        // `active` is deliberately ignored here. Which tab is frontmost is
        // `FocusRegionState`'s job, not the plan's: the daemon's `active`
        // pointer reaches it through `LayoutChangeClassifier`'s five-way
        // classification (W5, D4), which is what stops a content-only
        // republish from fighting the operator's own tab choice. A plan that
        // baked in `active` would re-select on every broadcast.
        let tabs = children.enumerated().map { index, child -> RegionTab in
            let childPath = RegionPath.tabChild(path, index)
            let region = regionNode(child, path: childPath, content: content)
            // A tab's "representative" pane — the one whose content kind
            // names it when the daemon supplied no label, and the id the
            // strip identifies the tab by. For the ordinary leaf case that's
            // the leaf itself; for a tab wrapping a nested split/tabs it's
            // the first leaf underneath, via `firstPaneId(of:)` below, which
            // always picks index 0 (a split's first child, a tabbed node's
            // first tab) and never consults `active`. That is NOT the same
            // rule as `firstLeafPaneId`/`PaneTree.firstLeaf` further down —
            // those resolve a tabs node's `active` pointer, because their
            // job is answering "what is actually shown". This one's job is
            // a stable label, which must not change just because the
            // operator switched which nested tab is frontmost — the same
            // reason `active` is ignored two lines above for this node's own
            // tabs. Empty only for a degenerate empty `tabs` node, which has
            // no leaf to name.
            let representative = firstPaneId(of: region) ?? ""
            let label = index < labels.count
                ? labels[index]
                : TabPlan.fallbackLabel(paneId: representative, content: content[representative])
            return RegionTab(
                entry: TabPlanEntry(
                    paneId:     representative,
                    label:      label,
                    regionPath: childPath,
                    tabIndex:   index
                ),
                content: region
            )
        }
        return .tabbed(path: path, tabs: tabs)
    }
}

/// The first leaf pane id reachable under `node`, taking a split's first
/// child and a tabbed region's first tab — always index 0, regardless of
/// which tab the daemon marked `active`. `nil` only for a region containing
/// no leaves at all (an empty `tabs` node).
///
/// Deliberately not the same rule as `firstLeafPaneId`/`PaneTree.firstLeaf`
/// below: this picks a stable label for a tab (see its call site in
/// `regionNode`), and a label that moved every time the operator switched a
/// nested tab would be worse than one that never reflects the switch at
/// all. The other two exist to resolve what a tabs node's `active` pointer
/// actually designates, which is the opposite goal.
private func firstPaneId(of node: RegionNode) -> String? {
    switch node {
    case .bare(_, let paneId):
        return paneId
    case .split(_, let children, _):
        for child in children {
            if let found = firstPaneId(of: child) { return found }
        }
        return nil
    case .tabbed(_, let tabs):
        for tab in tabs {
            if let found = firstPaneId(of: tab.content) { return found }
        }
        return nil
    }
}

// MARK: - Ratio normalisation

/// Turn the wire's `ratios` into `RegionNode.split`'s `shares`.
///
/// The daemon is authoritative about layout but is not trusted to be
/// well-formed: a `ratios` array that doesn't sum to 1, is shorter or longer
/// than `children`, or contains a zero, a negative, a `NaN` or an infinity
/// must still produce a usable plan. The PRD requires a malformed layout to
/// DEGRADE rather than blank a region, so this normalises rather than
/// asserting, and the rule is recorded here rather than being implicit in
/// arithmetic:
///
/// 1. Extra ratios beyond `childCount` are ignored.
/// 2. Any non-finite (`NaN`, `±inf`) or non-positive value becomes 0.
/// 3. If fewer ratios than children were supplied, each missing child gets
///    an equal slice of whatever remains of 1 after the supplied ones
///    (`max(0, 1 - sum)`), so `[0.6]` over three children is `[0.6, 0.2, 0.2]`.
/// 4. If nothing usable is left (empty array, all zeros), every child gets an
///    equal share.
/// 5. Otherwise the values are normalised to sum to 1, preserving their
///    proportions — `[3, 1]` is `[0.75, 0.25]`.
/// 6. Finally a floor of `min(0.05, 1/childCount)` is applied: any share
///    below it is raised to it and the deficit taken proportionally from the
///    rest, repeated until stable. The floor never perturbs an already-valid
///    split (`[0.6, 0.4]` stays `[0.6, 0.4]`) — it exists so that a region
///    the daemon assigned zero width to is still visible and tappable rather
///    than invisibly present.
///
/// Post-conditions, which the view depends on and `LayoutPlanTests` asserts
/// for every case: exactly `childCount` shares, each strictly positive, and
/// summing to 1.
func normalisedShares(ratios: [Double], childCount: Int) -> [Double] {
    guard childCount > 0 else { return [] }

    // 1 & 2 — truncate, then sanitize.
    var values = ratios.prefix(childCount).map { value -> Double in
        (value.isFinite && value > 0) ? value : 0
    }

    // 3 — fill the missing shares from the remainder.
    if values.count < childCount {
        let missing = childCount - values.count
        let remainder = Swift.max(0, 1 - values.reduce(0, +))
        values.append(contentsOf: repeatElement(remainder / Double(missing), count: missing))
    }

    // 4 — nothing usable at all.
    let total = values.reduce(0, +)
    guard total > 0 else {
        return Array(repeating: 1 / Double(childCount), count: childCount)
    }

    // 5 — normalise.
    var shares = values.map { $0 / total }

    // 6 — floor, redistributing proportionally. Bounded by `childCount`
    // passes: each pass either finishes or pins at least one more share to
    // the floor, so it cannot loop.
    let minShare = Swift.min(0.05, 1 / Double(childCount))
    for _ in 0..<childCount {
        let below = shares.indices.filter { shares[$0] < minShare }
        if below.isEmpty { break }
        let belowSet = Set(below)
        let above = shares.indices.filter { !belowSet.contains($0) }
        let aboveTotal = above.reduce(0.0) { $0 + shares[$1] }
        let budget = 1 - minShare * Double(below.count)
        for index in below { shares[index] = minShare }
        if aboveTotal > 0 {
            for index in above { shares[index] = shares[index] / aboveTotal * budget }
        } else if !above.isEmpty {
            let each = budget / Double(above.count)
            for index in above { shares[index] = each }
        }
    }
    return shares
}

// MARK: - LayoutRegions

/// Region lookups that don't need a plan in hand — used by `DaemonStore`,
/// which maintains region state for BOTH presentations without knowing (or
/// caring) which one is currently on screen. It can do that because region
/// paths are a pure function of the tree, not of the presentation: state
/// written while the iPad was landscape is found again the instant it turns
/// portrait, and vice versa. That is the whole mechanism behind D5's
/// losslessness.
public enum LayoutRegions {

    /// Every region path that could host `paneId` in either presentation of
    /// `tree`: the compact strip's single `RegionPath.root` region, plus the
    /// regular-width region containing it (its immediate `tabs` parent's
    /// path, or — for a leaf that is not a tabs child — the leaf's own path).
    /// Deduplicated: for a `tabs` node sitting at the tree root, both
    /// presentations name the same region and it is reported once. Empty
    /// when `paneId` is not in `tree` at all.
    public static func hostingPaths(of paneId: String, in tree: PaneTree) -> [String] {
        let regular = layoutPlan(tree: tree, width: .regular).regions
        guard let host = regular.first(where: { $0.paneIds.contains(paneId) }) else { return [] }
        return host.path == RegionPath.root ? [RegionPath.root] : [RegionPath.root, host.path]
    }

    /// Every region path present in either presentation of `tree` — what
    /// `FocusRegionState.prune` retains after a tree rebuild.
    public static func allPaths(in tree: PaneTree) -> Set<String> {
        var paths = Set(layoutPlan(tree: tree, width: .regular).regions.map(\.path))
        paths.insert(RegionPath.root)
        return paths
    }
}

extension LayoutRegions {

    /// The pane id the `tabs` node at `regionPath` designates active,
    /// resolved down to a leaf. `nil` when `regionPath` names no `tabs` node
    /// — a `.bare` region has no "active" concept and a `.split` has none of
    /// its own.
    ///
    /// This exists because `PaneTree.resolvedActivePaneId` deliberately
    /// declines to guess when two tabs nodes disagree: at compact width
    /// that's genuinely ambiguous (one strip, one frontmost thing), but at
    /// regular width the two nodes are two SEPARATE regions and each one's
    /// own `active` is exactly what its own strip should honour. Resolving
    /// per region is what makes "a show that changes the frontmost tab of
    /// one region does not change the frontmost tab of another" true of the
    /// tree's own pointers, not only of `focused_pane`.
    public static func activePane(forRegion regionPath: String, in tree: PaneTree) -> String? {
        func walk(_ node: PaneTree, _ nodePath: String) -> String? {
            if nodePath == regionPath, case .tabs(let children, _, let active) = node {
                let index = children.indices.contains(active) ? active : 0
                guard children.indices.contains(index) else { return nil }
                return firstLeafPaneId(children[index])
            }
            switch node {
            case .leaf:
                return nil
            case .split(_, let children, _):
                for (index, child) in children.enumerated() {
                    if let found = walk(child, RegionPath.splitChild(nodePath, index)) { return found }
                }
                return nil
            case .tabs(let children, _, _):
                for (index, child) in children.enumerated() {
                    if let found = walk(child, RegionPath.tabChild(nodePath, index)) { return found }
                }
                return nil
            }
        }
        return walk(tree, RegionPath.root)
    }
}

/// The first leaf reached by resolving each node's own designated child —
/// a split's first child (a split has no "active" concept), but a tabs
/// node's ACTIVE child, not its first. The same resolution rule
/// `PaneTree.firstLeaf` uses for `resolvedActivePaneId`
/// (`FocusRegionState.swift`), mirrored here because this file needs it for
/// `LayoutRegions.activePane(forRegion:in:)` and that one is private to its
/// own file. Not to be confused with `firstPaneId(of:)` above, which walks a
/// different type (`RegionNode`, already-built) and answers a different
/// question — a stable tab label that must NOT track `active`. `nil` for a
/// subtree with no leaves at all.
private func firstLeafPaneId(_ node: PaneTree) -> String? {
    switch node {
    case .leaf(let paneId):
        return paneId
    case .split(_, let children, _):
        for child in children {
            if let found = firstLeafPaneId(child) { return found }
        }
        return nil
    case .tabs(let children, _, let active):
        let index = children.indices.contains(active) ? active : 0
        guard children.indices.contains(index) else { return nil }
        return firstLeafPaneId(children[index])
    }
}
