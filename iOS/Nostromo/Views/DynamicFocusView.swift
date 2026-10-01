// Nostromo iOS — DynamicFocusView.swift
//
// Renders a focus's agent-authored pane tree on iOS (W5 — ios-curated-view-
// parity rewrite).
//
// On iOS, real split views are impractical on a small screen, so the tree is
// flattened "by meaning not geometry" into a single horizontal tab strip
// (`TabStripView`) via `TabPlan.build` — the `repl` pane is always first
// (backed by `TranscriptView`), and every other agent-created pane follows
// in tree order. When there is only a single `repl` pane (the initial
// state), the strip is suppressed entirely, exactly as before.
//
// This replaces the old per-pane `TabView`/`.tabItem` structure, which (a)
// nested a second bottom tab bar inside the app's own root five-tab bar, (b)
// labelled tabs via `paneId.capitalized` — the one place a raw pane id was
// user-visible anywhere in the app, and (c) never read the daemon's `active`
// index or `focused_pane` hint, so a deliberate `nostromo.show` never
// actually brought its tab to front on iOS. All three are fixed here:
// labels come from `TabPlan` (never a pane id), and frontmost-ness comes
// from `DaemonStore.focusRegionStates` (`FocusRegionState`), which honours
// `active`/`focused_pane` on a structural layout change while never fighting
// the operator's own tab choice on a content-only republish (D4).
//
// Every pane's content view is instantiated once via `ForEach(id: \.paneId)`
// and kept resident (visibility toggled via `.opacity`/`.allowsHitTesting`),
// not conditionally rebuilt on tab switch — the same "resident views, pure
// visibility toggle" technique macOS's `TabRegionView` uses so scroll
// position and view-local state survive a tab switch with no bookkeeping.
// `FocusRegionState` (in `DaemonStore`, not view `@State`) is what survives
// beyond that — a tree rebuild, backgrounding, or (W6) a width-class change.
//
// W6 (ios-curated-view-parity) adds the SECOND presentation. This file is
// the ONE place in the whole app that reads `@Environment(\.horizontalSizeClass)`
// — mapped once through `WidthClass`, passed down as a value, never re-read
// — and the one place that branches on it. Nothing anywhere branches on the
// device: no `UIDevice`, no `userInterfaceIdiom`, no `UIScreen`, no
// orientation notification, no size threshold in points. Both halves of the
// PRD's rule ("an iPad in a narrow multitasking window presents the compact
// layout; a phone never presents the regular one") follow from the size
// class for free, and both break the moment anything else is consulted;
// `tests/ios_policy/test_ios_view_policy.py` enforces that as an explicit
// allowlist so adding a consumer requires editing the policy and therefore
// noticing.
//
// The width class is the ONLY branch. Every renderer, every addressing
// behaviour, the ticker, the unread marks, the `reason` captions and the
// decision surface are identical in both presentations — compact and
// regular differ in how regions are ARRANGED and in nothing else. The
// compact path below is W5's, called through unchanged rather than
// reimplemented, and `LayoutPlanTests` asserts that equality directly.
//
// Losslessness across a live width-class change (D5) is achieved by having
// almost nothing to lose: frontmost tabs and unread marks were never in the
// view (they're in `DaemonStore`'s `FocusRegionState`, keyed by region path,
// and region paths are a pure function of the tree rather than of the
// presentation), and the activity sheet is presented from HERE — above the
// hierarchy a width change destroys — rather than from inside a region.
// Scroll position is the one thing that needs an explicit save and restore,
// because a compact/regular change genuinely restructures the view tree and
// the container that held a `ScrollView` is simply gone.

import SwiftUI
import NostromoKit

struct DynamicFocusView: View {
    let tag:         String
    let displayName: String
    let agentName:   String
    let viewName:    String
    let client:      NetworkClient

    @EnvironmentObject var store: DaemonStore
    /// Presents `ActivityStreamsSheet` (D5) — owned here, at the focus-view
    /// level, rather than by `TranscriptView` or `PaneSurfaceView`, so it
    /// survives a tab switch or rotation without disappearing underneath
    /// the operator.
    @State private var showActivitySheet = false

    /// THE width read — the only one in the app (D1). Read here, mapped once
    /// through `WidthClass`, and passed downward as a value; never re-read
    /// further down the tree, and never consulted alongside anything about
    /// the device.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    /// The region path used for the compact, single-strip presentation.
    private static let regionPath = FocusRegionState.compactRegion

    /// `nil` (SwiftUI reporting no size class) and compact both mean
    /// compact — the rule lives in `WidthClass.from(isRegular:)` so it is a
    /// tested function rather than an inline `?? .compact` inside a view.
    private var width: WidthClass {
        WidthClass.from(isRegular: horizontalSizeClass.map { $0 == .regular })
    }

    var body: some View {
        let layout = store.focusLayouts[tag] ?? FocusLayoutModel.initial
        let plan   = layoutPlan(tree: layout.tree, width: width, content: layout.paneContent)

        Group {
            switch plan {
            case .singleRegion(let entries):
                if entries.count <= 1 {
                    // Single pane: no tab chrome; identical to the previous
                    // TranscriptView experience.
                    transcriptView
                } else {
                    tabbedContent(plan: entries, layout: layout)
                }
            case .regions(let node):
                regionContent(node: node, layout: layout)
            }
        }
        // Per-focus PR under review (W8) — a fixed-height top bar, present
        // for every layout kind (single pane, tabbed strip, or regular-width
        // regions) rather than threaded through each branch individually, so
        // it can never be silently missing from one of them. Same "never
        // absent, never changes height" contract as `activityTicker` below,
        // mirrored at the opposite edge.
        .safeAreaInset(edge: .top) { prLabelBar }
        // Presented from the focus view — ABOVE the region hierarchy a
        // width-class change tears down — so an open activity surface
        // survives a rotation or a multitasking resize (W4 D5, W6 D5). A
        // sheet presented from inside a region would vanish under the
        // operator the instant the iPad turned; the L2 policy suite asserts
        // structurally that none is.
        .sheet(isPresented: $showActivitySheet) {
            ActivityStreamsSheet(model: activityModel)
        }
        // D8: published downward as a VALUE so a surface renderer never has
        // to re-read the size class. The sole intended consumer is the
        // `pr_diff` renderer (W8), whose file-list-beside-hunks arrangement
        // at regular width is a property of that renderer rather than of the
        // region layout. Nothing else may read it — the L2 policy suite
        // holds an explicit allowlist.
        .environment(\.nostromoWidthClass, width)
    }

    // MARK: - Regular width: real regions (W6)

    /// The daemon's splits as real, simultaneously-visible regions. The
    /// arrangement comes entirely from `layoutPlan`; this view supplies only
    /// the per-pane surfaces, which are the same ones the compact strip
    /// renders.
    private func regionContent(node: RegionNode, layout: FocusLayoutModel) -> some View {
        let region = store.focusRegionStates[tag] ?? FocusRegionState()
        return RegionContainerView(
            node:           node,
            region:         region,
            contentVersion: layout.paneContentVersion,
            reason:         { paneId in layout.paneAddress[paneId]?.reason },
            onSelect:       { regionPath, paneId in
                store.selectPane(tag: tag, regionPath: regionPath, paneId: paneId)
            },
            surface:        { paneId in paneContentView(for: paneId, layout: layout) }
        )
        .navigationTitle(displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Multi-pane presentation

    /// The tab strip plus its resident, visibility-toggled pane content —
    /// only ever reached when `plan` has more than one entry (see `body`).
    private func tabbedContent(plan: [TabPlanEntry], layout: FocusLayoutModel) -> some View {
        let region    = store.focusRegionStates[tag] ?? FocusRegionState()
        let available = plan.map(\.paneId)
        let frontmost = region.frontmostPane(for: Self.regionPath, available: available, fallback: "repl")
        let reason    = layout.paneAddress[frontmost]?.reason

        return VStack(spacing: 0) {
            TabStripView(
                entries: plan,
                frontmostPaneId: frontmost,
                reason: reason,
                isUnread: { paneId in
                    region.isUnread(
                        paneId: paneId, regionPath: Self.regionPath,
                        contentVersion: layout.paneContentVersion[paneId] ?? 0
                    )
                },
                onSelect: { paneId in
                    store.selectPane(tag: tag, regionPath: Self.regionPath, paneId: paneId)
                }
            )

            ZStack {
                ForEach(plan, id: \.paneId) { entry in
                    paneContentView(for: entry.paneId, layout: layout)
                        .opacity(entry.paneId == frontmost ? 1 : 0)
                        .allowsHitTesting(entry.paneId == frontmost)
                        .accessibilityHidden(entry.paneId != frontmost)
                }
            }
        }
        .navigationTitle(plan.first(where: { $0.paneId == frontmost })?.label ?? displayName)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Per-pane content

    @ViewBuilder
    private func paneContentView(for paneId: String, layout: FocusLayoutModel) -> some View {
        if paneId == "repl" {
            transcriptView
        } else {
            PaneSurfaceView(
                paneId:    paneId,
                content:   layout.paneContent[paneId],
                freshness: layout.paneFreshness[paneId],
                address:   layout.paneAddress[paneId],
                saveScrollKey: { key in store.setScrollKey(tag: tag, paneId: paneId, key: key) },
                restoreScroll: { range in
                    store.scrollRestore(tag: tag, paneId: paneId, visibleRange: range)
                },
                saveDiffFileScrollKey: { file, key in
                    store.setDiffFileScrollKey(tag: tag, paneId: paneId, file: file, key: key)
                },
                restoreDiffFileScrollKey: { file, range in
                    store.diffFileScrollRestore(tag: tag, paneId: paneId, file: file, visibleRange: range)
                },
                saveSelectedDiffFile: { path, identity in
                    store.setSelectedDiffFile(tag: tag, paneId: paneId, path: path, identity: identity)
                },
                restoreSelectedDiffFile: { identity in
                    store.selectedDiffFile(tag: tag, paneId: paneId, identity: identity)
                }
            )
            .environmentObject(store)
            // Ambient activity (W4, D3): a plain bottom inset on non-repl
            // surfaces, which have no input bar of their own to compose
            // above. Re-hosted here after the W5 rewrite (D9) — every
            // non-repl surface still carries the ticker.
            .safeAreaInset(edge: .bottom) { activityTicker }
        }
    }

    // MARK: - Ambient activity (ios-curated-view-parity W4)

    /// This focus's assembled activity model — an empty (neutral "waiting")
    /// model when nothing has arrived for this tag yet, never `nil`.
    private var activityModel: ActivityStreamModel {
        store.activityModels[tag] ?? ActivityStreamModel()
    }

    private var activityTicker: some View {
        ActivityTickerBar(
            text: activityModel.displayText(health: store.activityHealth),
            onTap: { showActivitySheet = true }
        )
    }

    // MARK: - Per-focus PR under review (W8)

    /// This focus's PR under review, or the explicit "no PR" string — never
    /// empty, never absent. The PR always wins over any other candidate
    /// (there's no session-summary/disambiguation fallback in a per-focus
    /// view the way there is in the sidebar/focus-list row, so `fallback` is
    /// always `nil` here).
    private var prLabelBar: some View {
        let pr = store.perriCurrentPr(for: tag)
        let text = FocusPRLabel.secondary(repo: pr?.repo, number: pr?.prNumber, fallback: nil)
        return PRLabelBar(text: text)
    }

    // MARK: - Sub-views

    private var transcriptView: some View {
        TranscriptView(
            tag:         tag,
            displayName: displayName,
            agentName:   agentName,
            viewName:    viewName,
            client:      client,
            // Owned by `DaemonStore`, not by the view (D5): a width-class
            // change rebuilds this hierarchy, and a view-owned store would
            // blank the transcript and re-request it from the daemon.
            store:       store.transcriptStore(for: tag),
            saveScrollKey: { key in store.setScrollKey(tag: tag, paneId: "repl", key: key) },
            restoreScroll: { range in
                store.scrollRestore(tag: tag, paneId: "repl", visibleRange: range)
            },
            bottomAccessory: { activityTicker }
        )
    }
}
