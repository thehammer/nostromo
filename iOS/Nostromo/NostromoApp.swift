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
                    // Show settings if no host has been configured yet.
                    if ConnectionSettings.isDefault {
                        showSettings = true
                    } else {
                        store.start()
                    }
                }
                .sheet(isPresented: $showSettings, onDismiss: {
                    store.start()
                }) {
                    ConnectionSettingsView(store: store)
                }
        }
    }
}

/// Root content view — TabView with Sessions and Queue tabs.
struct ContentView: View {
    @EnvironmentObject var store: DaemonStore

    var body: some View {
        TabView {
            SessionsTab()
                .tabItem { Label("Sessions", systemImage: "list.bullet.rectangle") }

            QueueTab()
                .tabItem { Label("Queue", systemImage: "tray.full") }
                .badge(activeJobCount)

            PerriTab()
                .tabItem { Label("Perri", systemImage: "checkmark.seal") }
                .badge(store.perriQueue.count)
        }
    }

    private var activeJobCount: Int {
        store.motherJobs.filter {
            ["running", "queued", "ready", "awaiting"].contains($0.state)
        }.count
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
            ConnectionSettingsView(store: store)
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
