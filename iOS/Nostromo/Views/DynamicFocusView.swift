// Nostromo iOS — DynamicFocusView.swift
//
// Renders a focus's agent-authored pane tree on iOS.
//
// On iOS, real split views are impractical on a small screen.  This view
// renders panes "by meaning not geometry": the `repl` pane is always the
// primary tab (backed by TranscriptView), and additional agent-created panes
// become extra tabs whose content is rendered from the `PaneContentWire`
// pushed by `set_pane_content`.
//
// When there is only a single `repl` pane (the initial state), the TabView
// chrome is suppressed entirely so the layout is identical to the previous
// direct-to-TranscriptView navigation.

import SwiftUI
import NostromoKit

struct DynamicFocusView: View {
    let tag:         String
    let displayName: String
    let agentName:   String
    let viewName:    String
    let client:      NetworkClient

    @EnvironmentObject var store: DaemonStore
    @State private var selectedTab: String = "repl"
    /// Presents `ActivityStreamsSheet` (D5) — owned here, at the focus-view
    /// level, rather than by `TranscriptView` or `PaneSurfaceView`, so it
    /// survives a tab switch or rotation without disappearing underneath
    /// the operator.
    @State private var showActivitySheet = false

    var body: some View {
        let layout  = store.focusLayouts[tag] ?? FocusLayoutModel.initial
        let paneIds = layout.tree.paneIds

        Group {
            if paneIds.count <= 1 {
                // Single pane: no tab chrome; identical to the previous TranscriptView experience.
                transcriptView
            } else {
                // Multiple panes: TabView with repl first, then agent-created panes.
                TabView(selection: $selectedTab) {
                    transcriptView
                        .tag("repl")
                        .tabItem { Label("Repl", systemImage: "terminal") }

                    ForEach(paneIds.filter { $0 != "repl" }, id: \.self) { paneId in
                        PaneSurfaceView(
                            paneId: paneId,
                            content: layout.paneContent[paneId],
                            freshness: layout.paneFreshness[paneId],
                            address: layout.paneAddress[paneId]
                        )
                            .environmentObject(store)
                            // Ambient activity (W4, D3): a plain bottom inset
                            // on non-repl surfaces, which have no input bar
                            // of their own to compose above.
                            .safeAreaInset(edge: .bottom) { activityTicker }
                            .navigationTitle(paneId.capitalized)
                            .navigationBarTitleDisplayMode(.inline)
                            .tag(paneId)
                            .tabItem {
                                Label(paneId.capitalized, systemImage: "rectangle.split.2x1")
                            }
                    }
                }
                .navigationTitle(selectedTab == "repl" ? displayName : selectedTab.capitalized)
                .navigationBarTitleDisplayMode(.inline)
                // Reset to repl if the selected pane is removed by reset_panes.
                .onChange(of: paneIds) { _, newIds in
                    if !newIds.contains(selectedTab) { selectedTab = "repl" }
                }
            }
        }
        .sheet(isPresented: $showActivitySheet) {
            ActivityStreamsSheet(model: activityModel)
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

