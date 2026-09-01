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

    /// The region path used for the compact, single-strip presentation this
    /// wedge implements (W6 adds real per-region paths at regular width).
    private static let regionPath = FocusRegionState.compactRegion

    var body: some View {
        let layout = store.focusLayouts[tag] ?? FocusLayoutModel.initial
        let plan   = TabPlan.build(tree: layout.tree, content: layout.paneContent)

        Group {
            if plan.count <= 1 {
                // Single pane: no tab chrome; identical to the previous
                // TranscriptView experience.
                transcriptView
            } else {
                tabbedContent(plan: plan, layout: layout)
            }
        }
        .sheet(isPresented: $showActivitySheet) {
            ActivityStreamsSheet(model: activityModel)
        }
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
                address:   layout.paneAddress[paneId]
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

    // MARK: - Sub-views

    private var transcriptView: some View {
        TranscriptView(
            tag:         tag,
            displayName: displayName,
            agentName:   agentName,
            viewName:    viewName,
            client:      client,
            bottomAccessory: { activityTicker }
        )
    }
}
