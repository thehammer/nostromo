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
