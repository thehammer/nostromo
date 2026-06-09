// Nostromo iOS — DaemonDiscoveryView.swift
//
// Primary connection UI.  Browses for _nostromo._tcp services via Bonjour
// and auto-connects when exactly one daemon is found after the settle window.
// Falls back to ConnectionSettingsView for manual entry when needed.

import SwiftUI
import NostromoKit

struct DaemonDiscoveryView: View {
    let store: DaemonStore

    @StateObject private var discovery = DaemonDiscovery()
    @Environment(\.dismiss) private var dismiss

    @State private var showManual    = false
    @State private var connectingTo: String?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Connect to nostromd")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
        }
        .onAppear {
            discovery.start()
        }
        .onDisappear {
            discovery.stop()
        }
        .sheet(isPresented: $showManual) {
            ConnectionSettingsView(store: store)
        }
        .onChange(of: discovery.state) { _, newState in
            handleStateChange(newState)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch discovery.state {

        case .idle, .browsing:
            browsingView

        case .found(let daemons) where daemons.count == 1:
            // Single daemon — show connecting status (auto-connect fires in onChange).
            connectingView(for: daemons[0])

        case .found(let daemons):
            // Multiple daemons — show a picker.
            pickerView(daemons: daemons)

        case .none:
            notFoundView
        }
    }

    // MARK: - State views

    private var browsingView: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Looking for nostromd on your network…")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func connectingView(for daemon: DiscoveredDaemon) -> some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Connecting to \(daemon.name)…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func pickerView(daemons: [DiscoveredDaemon]) -> some View {
        List(daemons) { daemon in
            Button {
                connect(to: daemon)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(daemon.name)
                        .font(.body)
                    Text(daemon.hostName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay(alignment: .top) {
            Text("Multiple daemons found — choose one:")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.top, 8)
        }
    }

    private var notFoundView: some View {
        VStack(spacing: 24) {
            Image(systemName: "network.slash")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Couldn't find nostromd on this network.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button("Try Again") {
                discovery.start()
            }
            .buttonStyle(.borderedProminent)

            Button("Enter Manually") {
                showManual = true
            }
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Logic

    private func handleStateChange(_ state: DiscoveryState) {
        guard case .found(let daemons) = state, daemons.count == 1 else { return }

        // Single daemon found — wait the settle interval then auto-connect.
        let daemon = daemons[0]
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(discovery.settleInterval * 1_000_000_000))
            // Re-check: user may have dismissed or another daemon may have appeared.
            guard case .found(let current) = discovery.state, current.count == 1 else { return }
            connect(to: daemon)
        }
    }

    private func connect(to daemon: DiscoveredDaemon) {
        discovery.stop()
        // Persist the .local host name so future launches reconnect by name,
        // not by raw IP.
        ConnectionSettings.save(host: daemon.hostName, port: ConnectionSettings.defaultPort)
        store.client.connect(to: daemon.endpoint)
        store.start()
        dismiss()
    }
}

#Preview {
    DaemonDiscoveryView(store: {
        let client = NetworkClient(host: "127.0.0.1", port: 47100)
        return DaemonStore(client: client)
    }())
}
