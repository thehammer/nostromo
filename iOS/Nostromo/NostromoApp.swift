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

/// Root content view — shows FocusListView once connected, a progress
/// indicator while connecting, and the settings sheet when disconnected.
struct ContentView: View {
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
