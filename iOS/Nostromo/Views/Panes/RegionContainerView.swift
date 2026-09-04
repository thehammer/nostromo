// Nostromo iOS — RegionContainerView.swift
//
// Renders a `RegionNode` at regular width (W6 — ios-curated-view-parity,
// D3/D6): the daemon's splits as real, simultaneously-visible regions, in
// the daemon's directions, proportioned by the daemon's ratios. iOS has
// never rendered a split before this — W5 flattens the whole tree into one
// strip, which is the right answer at phone width and is what the app has
// always done. An iPad in landscape can hold two surfaces at once, and
// "read the acceptance criterion and the diff at the same time" is the
// specific act a phone cannot perform.
//
// Recursive, so nesting is real nesting: a `.split` whose child is a
// `.split` produces regions within regions, and a `.tabbed` whose tab
// content is a region produces a region within a tab. The obvious shortcut
// — walking to depth one and treating everything below as a leaf —
// produces a plausible-looking layout that silently loses panes.
//
// This view computes NO layout proportion of its own. Every fraction it
// divides space by comes from `RegionNode.split`'s `shares`, which
// `layoutPlan` already normalised (one per child, strictly positive,
// summing to 1) — the layout DECISION is a pure function tested by
// `LayoutPlanTests` with no device and no simulator, and this file's job is
// to obey it. That division of labour is the only defence this wedge has:
// there is no iOS test target and no simulator in CI.
//
// D6 — THE DIVIDER IS A SEPARATOR, NOT A HANDLE. There is deliberately no
// drag gesture, no grab affordance, no hover or press feedback, no
// collapse/expand, and no locally persisted ratio. A visible divider
// between two regions is an obvious thing to try to drag, so the reason is
// recorded here rather than left to be rediscovered: macOS's
// ratio-persistence machinery (`clearSavedRatios`, the
// `nostromo.dynlayout.<tag>.<path>` defaults keys, and the split-signature
// classifier) is the hairiest part of the macOS layout code, and the parent
// PRD flagged it as a hazard that silently eats the operator's dragged
// layout when tabs churn. Deferring the gesture keeps the layout decision a
// pure function of (tree, width class), which is what makes it testable
// without a device. Adding the gesture later is additive — honouring the
// daemon's ratios is its prerequisite either way — and should not be
// attempted without first reading what macOS's `clearSavedRatios` had to do.
import SwiftUI
import NostromoKit

struct RegionContainerView<Surface: View>: View {

    let node: RegionNode
    /// This focus's region state, read for each region's own frontmost tab
    /// and unread marks. Passed down as a value rather than re-read per
    /// region — it lives in `DaemonStore`, never in view `@State`, which is
    /// exactly why it survives the width-class change that destroys this
    /// whole view hierarchy.
    let region: FocusRegionState
    /// Per-pane current content version, for the unread predicate.
    let contentVersion: [String: Int]
    /// The frontmost pane's `PaneAddress.reason` — the caption under a
    /// region's strip, identical to the compact presentation's.
    let reason: (String) -> String?
    let onSelect: (_ regionPath: String, _ paneId: String) -> Void
    /// Builds one pane's surface. The SAME builder the compact presentation
    /// uses: no renderer differs between widths.
    let surface: (String) -> Surface

    var body: some View {
        switch node {
        case .bare(_, let paneId):
            AnyView(surface(paneId))

        case .split(let direction, let children, let shares):
            AnyView(splitView(direction: direction, children: children, shares: shares))

        case .tabbed(let path, let tabs):
            AnyView(tabbedView(path: path, tabs: tabs))
        }
    }

    // MARK: - Split

    /// `SplitDirection.horizontal` means a VERTICAL divider (left | right),
    /// so it lays out in an `HStack`; `.vertical` means a horizontal divider
    /// (top over bottom) and lays out in a `VStack`. See
    /// `PaneLayout.swift:14-20` — getting this backwards produces a layout
    /// that looks deliberate and is wrong.
    private func splitView(direction: SplitDirection, children: [RegionNode], shares: [Double]) -> some View {
        GeometryReader { geometry in
            let dividerTotal = Double(max(0, children.count - 1)) * Self.dividerThickness
            let span = direction == .horizontal ? geometry.size.width : geometry.size.height
            let usable = max(0, Double(span) - dividerTotal)

            // Each region is sized on the split's axis from the plan's
            // shares and filled on the cross axis — a region that sized
            // itself to its content on the cross axis would collapse to the
            // height of whatever it happens to be showing.
            //
            // The two arms below differ only in which dimension gets
            // `usable * share(...)` and which gets `geometry`'s raw span —
            // deliberately left as two arms rather than factored into one,
            // because `HStack` and `VStack` are different types in SwiftUI
            // and unifying them means either type-erasing every child (an
            // `AnyView` per region on top of the one `recurse` already
            // applies) or reaching for the `Layout` protocol, both of which
            // are more machinery than four lines of arithmetic justify.
            if direction == .horizontal {
                HStack(spacing: 0) {
                    ForEach(Array(children.enumerated()), id: \.offset) { index, childNode in
                        if index > 0 { divider(.vertical) }
                        recurse(childNode)
                            .frame(width: usable * share(shares, index), height: geometry.size.height)
                    }
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(children.enumerated()), id: \.offset) { index, childNode in
                        if index > 0 { divider(.horizontal) }
                        recurse(childNode)
                            .frame(width: geometry.size.width, height: usable * share(shares, index))
                    }
                }
            }
        }
    }

    /// A region's share of its parent's span, taken from the plan and never
    /// computed here. The fallback is defensive only: `layoutPlan`
    /// guarantees one strictly-positive share per child summing to 1, for
    /// well-formed and malformed daemon input alike, and `LayoutPlanTests`
    /// asserts that invariant for every case. This exists so a shape
    /// mismatch degrades to an equal division rather than collapsing a
    /// region to zero width on screen.
    private func share(_ shares: [Double], _ index: Int) -> Double {
        guard shares.indices.contains(index) else {
            return 1 / Double(max(1, shares.count))
        }
        return shares[index]
    }

    /// A hairline separator. NOT a handle — see D6 in the file header.
    /// Deliberately plain: no grab dots, no wider hit area, no pressed or
    /// hovered appearance. It must not invite an attempt to drag it.
    private func divider(_ axis: Axis) -> some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.25))
            .frame(
                width:  axis == .vertical   ? Self.dividerThickness : nil,
                height: axis == .horizontal ? Self.dividerThickness : nil
            )
            .frame(maxHeight: axis == .vertical ? .infinity : nil)
            .frame(maxWidth: axis == .horizontal ? .infinity : nil)
            .accessibilityHidden(true)
    }

    /// Hairline thickness in points — a separator's stroke, not a layout
    /// fraction. Every fraction this view divides space by comes from the
    /// plan's `shares`.
    private static var dividerThickness: Double { 1 }

    // MARK: - Tabbed

    /// A region with its own strip and its own frontmost tab (D4). One
    /// `TabStripView` per `.tabbed` node — the view W5 built parameterised
    /// by region for exactly this — each reading and writing
    /// `FocusRegionState` at its OWN region path, which is what makes a show
    /// into one region leave another region's frontmost tab alone.
    private func tabbedView(path: String, tabs: [RegionTab]) -> some View {
        let entries = tabs.map(\.entry)
        let available = entries.map(\.paneId)
        let frontmost = region.frontmostPane(
            for: path,
            available: available,
            fallback: available.first ?? ""
        )

        return VStack(spacing: 0) {
            TabStripView(
                entries: entries,
                frontmostPaneId: frontmost,
                reason: reason(frontmost),
                isUnread: { paneId in
                    region.isUnread(
                        paneId: paneId, regionPath: path,
                        contentVersion: contentVersion[paneId] ?? 0
                    )
                },
                onSelect: { paneId in onSelect(path, paneId) }
            )

            // Resident, visibility-toggled tab content — every tab's view is
            // built once and kept alive, exactly as the compact strip and
            // macOS's `TabRegionView` do, so switching tabs is a visibility
            // toggle rather than a rebuild and scroll position survives a
            // switch with no bookkeeping.
            ZStack {
                ForEach(tabs, id: \.entry.paneId) { tab in
                    recurse(tab.content)
                        .opacity(tab.entry.paneId == frontmost ? 1 : 0)
                        .allowsHitTesting(tab.entry.paneId == frontmost)
                        .accessibilityHidden(tab.entry.paneId != frontmost)
                }
            }
        }
    }

    // MARK: - Recursion

    /// Type-erased on purpose: a SwiftUI view whose `body` mentions its own
    /// opaque return type is a circular type reference the compiler refuses.
    /// `AnyView` is the standard way to express a genuinely recursive view
    /// hierarchy, and the recursion here is the whole point — nesting is
    /// real nesting (D3).
    private func recurse(_ node: RegionNode) -> AnyView {
        AnyView(
            RegionContainerView(
                node:           node,
                region:         region,
                contentVersion: contentVersion,
                reason:         reason,
                onSelect:       onSelect,
                surface:        surface
            )
        )
    }
}

// MARK: - Previews
//
// D7: there is deliberately NO runtime override, debug menu, or launch
// argument for previewing the regular layout on a phone. A phone never
// presents the regular layout — that's the spec, and a demo affordance would
// be a second branch, which is exactly the accumulation the PRD names as the
// revisit condition for this whole design. The real check that the regular
// layout is right is `LayoutPlanTests`, which runs with no device at all;
// these previews are a development convenience for looking at the arrangement
// on the way past, nothing more.

#Preview("Two tabbed regions, 60/40") {
    let tree = PaneTree.split(
        direction: .horizontal,
        children: [
            .tabs(children: [.leaf(paneId: "repl"), .leaf(paneId: "queue")],
                  labels: ["Repl", "Queue"], active: 0),
            .tabs(children: [.leaf(paneId: "diff"), .leaf(paneId: "file")],
                  labels: ["Diff", "File"], active: 0),
        ],
        ratios: [0.6, 0.4]
    )
    guard case .regions(let node) = layoutPlan(tree: tree, width: .regular) else {
        return AnyView(Text("no regions"))
    }
    return AnyView(
        RegionContainerView(
            node:           node,
            region:         FocusRegionState(),
            contentVersion: [:],
            reason:         { _ in "shown because the acceptance criterion names it" },
            onSelect:       { _, _ in },
            surface:        { paneId in
                Text(paneId)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.secondary.opacity(0.08))
            }
        )
        .environment(\.nostromoWidthClass, .regular)
        .environment(\.horizontalSizeClass, .regular)
    )
}

#Preview("Nested split inside a split") {
    let tree = PaneTree.split(
        direction: .vertical,
        children: [
            .split(direction: .horizontal,
                   children: [.leaf(paneId: "repl"), .leaf(paneId: "diff")],
                   ratios: [0.5, 0.5]),
            .leaf(paneId: "queue"),
        ],
        ratios: [0.7, 0.3]
    )
    guard case .regions(let node) = layoutPlan(tree: tree, width: .regular) else {
        return AnyView(Text("no regions"))
    }
    return AnyView(
        RegionContainerView(
            node:           node,
            region:         FocusRegionState(),
            contentVersion: [:],
            reason:         { _ in nil },
            onSelect:       { _, _ in },
            surface:        { paneId in
                Text(paneId)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.secondary.opacity(0.08))
            }
        )
        .environment(\.nostromoWidthClass, .regular)
        .environment(\.horizontalSizeClass, .regular)
    )
}
