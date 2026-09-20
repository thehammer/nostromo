// Nostromo iOS — NostromoApp.swift
//
// SwiftUI app entry point.  Instantiates DaemonStore as the root @StateObject
// so every view in the hierarchy can access it via @EnvironmentObject.
//
// On first launch (or whenever no host is saved) ConnectionSettingsView is
// presented as a sheet so the user can enter the Mac's LAN IP and port.

import SwiftUI
import NostromoKit

@main
struct NostromoApp: App {

    @StateObject private var store: DaemonStore = {
        let (host, port) = ConnectionSettings.load()
        let client = NetworkClient(host: host, port: port)
        return DaemonStore(client: client)
    }()

    @State private var showSettings = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .onAppear {
                    // On first launch, open discovery so the user doesn't need
                    // to type an IP.  DaemonDiscoveryView calls store.start()
                    // on successful connect; we call it here for subsequent
                    // launches where the host is already saved.
                    if ConnectionSettings.isDefault {
                        showSettings = true
                    } else {
                        store.start()
                    }
                }
                .sheet(isPresented: $showSettings, onDismiss: {
                    // Only start if DaemonDiscoveryView didn't already start it.
                    if !store.client.connected {
                        store.start()
                    }
                }) {
                    DaemonDiscoveryView(store: store)
                }
        }
    }
}

/// Root content view — TabView with Sessions, Queue, Perri, Fred, and Teri tabs.
struct ContentView: View {
    @EnvironmentObject var store: DaemonStore

    enum Tab: Hashable { case sessions, queue, perri, fred, teri }
    @State private var selection: Tab = .sessions
    /// The `requestId` of the decision actually on screen right now, captured
    /// at presentation time (see `.onAppear` below) — never re-derived from
    /// the live queue head. `pendingDecisions.first` can change out from
    /// under a presented sheet (e.g. a `decision_resolved` broadcast for
    /// request A arrives and removes it while A's sheet is still mid-dismiss
    /// on screen, promoting B to the head). If the swipe-to-dismiss setter
    /// below re-read the live head instead of this captured id, an operator
    /// swipe on A's sheet could fire `closeDecision` for B — a spurious
    /// Dismissed on a decision the operator never even looked at. Capturing
    /// identity at presentation time makes that race structurally
    /// impossible.
    @State private var presentedDecisionRequestId: String?

    var body: some View {
        TabView(selection: $selection) {
            SessionsTab()
                .tag(Tab.sessions)
                .tabItem { Label("Sessions", systemImage: "list.bullet.rectangle") }

            QueueTab()
                .tag(Tab.queue)
                .tabItem { Label("Queue", systemImage: "tray.full") }
                .badge(activeJobCount)

            PerriTab()
                .tag(Tab.perri)
                .tabItem { Label("Perri", systemImage: "checkmark.seal") }
                .badge(store.perriQueue.count)

            FredTab(onStartAgent: { selection = .sessions })
                .tag(Tab.fred)
                .tabItem { Label("Fred", systemImage: "envelope") }
                .badge(unreadCount)

            TeriTab()
                .tag(Tab.teri)
                .tabItem { Label("Teri", systemImage: "checklist") }
                .badge(openTodoCount)
        }
        // Decision modals present above the root TabView (ios-curated-view-
        // parity W3, D1) — never from a region/focus view — so a decision
        // arriving while the operator is on, say, the Fred tab leaves them
        // on the Fred tab, and this surface is never inside a lazy
        // container (the recycle-and-re-arm shape that forced
        // TurnInteractionStore into existence on macOS for AskQuestionView).
        .sheet(item: Binding<PendingDecision?>(
            get: { store.pendingDecisions.first },
            set: { newValue in
                // SwiftUI calls this setter when the PRESENTATION wants to
                // write the binding back to nil — i.e. the operator swiped
                // the sheet away without tapping a choice or Dismiss. It is
                // NOT called when `pendingDecisions` changes for some other
                // reason (a tap-driven answer, or DaemonStore removing an
                // entry the daemon reported resolved elsewhere) — those
                // dismiss the sheet by changing the `get` side, with no
                // wire traffic from here. That asymmetry is what makes a
                // system-initiated close send nothing (D5): only a genuine
                // operator swipe ever reaches this closure.
                //
                // Deliberately targets `presentedDecisionRequestId`, NOT
                // `store.pendingDecisions.first` read fresh here — the live
                // queue head can have already moved on to a different
                // request by the time this fires (see the property's doc
                // comment), and answering the wrong request is exactly the
                // failure this surface exists to prevent.
                if newValue == nil, let requestId = presentedDecisionRequestId {
                    closeDecision(.operatorDismissed, for: requestId)
                }
            }
        )) { request in
            DecisionSheetView(
                request: request,
                askingFocusName: store.focuses[request.tag]?.displayName,
                resolution: store.decisionStore.resolution(for: request.requestId),
                onClose: { reason in
                    switch reason {
                    case .operatorChose(let choiceId):
                        closeDecision(.operatorChose(choiceId), for: request.requestId)
                    case .operatorDismissed:
                        closeDecision(.operatorDismissed, for: request.requestId)
                    case .supersededByDaemon:
                        // No code path in DecisionSheetView constructs this
                        // case (see its doc comment) — kept here only so
                        // the switch stays exhaustive if that ever changes.
                        break
                    }
                }
            )
            // Captures which request is actually on screen, at the moment
            // it's presented — see `presentedDecisionRequestId`'s doc
            // comment. `request` here is the value SwiftUI already
            // committed to presenting, not a live re-read, so this is safe
            // even if `pendingDecisions` mutates immediately afterward.
            .onAppear { presentedDecisionRequestId = request.requestId }
        }
    }

    /// The one place `DecisionStore.claimAnswer` and `DaemonStore.answerDecision`
    /// are called from — claiming before sending is what makes a second,
    /// contradictory answer for the same request structurally impossible on
    /// this client. `.supersededByDaemon` never reaches here (see
    /// `DecisionCloseReason`'s doc comment): a system-initiated close is
    /// realized by `DaemonStore` removing the request from
    /// `pendingDecisions` directly, which dismisses this sheet with no call
    /// through this function at all.
    private func closeDecision(_ reason: DecisionCloseReason, for requestId: String) {
        let choiceId: String?
        switch reason {
        case .operatorChose(let id): choiceId = id
        case .operatorDismissed:     choiceId = nil
        case .supersededByDaemon:    return
        }

        let record: DecisionResolutionRecord = choiceId.map { .choice($0) } ?? .dismissed
        if store.decisionStore.claimAnswer(requestId: requestId, record: record) {
            store.answerDecision(requestId: requestId, choiceId: choiceId)
        }
    }

    private var activeJobCount: Int {
        store.motherJobs.filter {
            ["running", "queued", "ready", "awaiting"].contains($0.state)
        }.count
    }

    private var unreadCount: Int {
        store.fredMailbox?.unreadCount ?? 0
    }

    /// Count of active todos for the tab badge.
    private var openTodoCount: Int {
        store.teriTodos?.items.count ?? 0
    }
}

// MARK: - SessionsTab

private struct SessionsTab: View {
    @EnvironmentObject var store: DaemonStore
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            FocusListView()
                .navigationTitle("Nostromo")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "network")
                        }
                    }
                }
        }
        .sheet(isPresented: $showSettings) {
            DaemonDiscoveryView(store: store)
        }
    }
}

// MARK: - QueueTab

private struct QueueTab: View {
    var body: some View {
        NavigationStack {
            MotherQueueView()
                .navigationTitle("Queue")
        }
    }
}

// MARK: - PerriTab

private struct PerriTab: View {
    var body: some View {
        NavigationStack {
            PerriView()
                .navigationTitle("Perri")
        }
    }
}

// MARK: - FredTab

private struct FredTab: View {
    var onStartAgent: () -> Void = {}

    var body: some View {
        NavigationStack {
            FredView(onStartAgent: onStartAgent)
                .navigationTitle("Fred")
        }
    }
}

// MARK: - TeriTab

private struct TeriTab: View {
    var body: some View {
        NavigationStack {
            TeriView()
                .navigationTitle("Teri")
        }
    }
}
