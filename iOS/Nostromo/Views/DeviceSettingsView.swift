// Nostromo iOS — DeviceSettingsView.swift
//
// Device Settings: the server address (editable without re-pairing), this device's name, the one
// Q2 sentence where a sharing scope would be (no control: nothing can be turned on), Un-pair, and
// Advanced -> Local network (legacy), which is the only way to the old TCP transport.

import SwiftUI
import NostromoKit

struct DeviceSettingsView: View {
    @EnvironmentObject var session: AppSession
    @Environment(\.dismiss) private var dismiss

    @State private var address: String = ""
    @State private var confirmUnpair = false
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Server address") {
                    TextField("10.0.0.5", text: $address)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onSubmit(saveAddress)
                    Button("Save Address", action: saveAddress)
                        .disabled(EnterCodeView.parse(address: address) == nil || address == session.serverAddress)
                }
                Section("This \(session.kindName)") {
                    LabeledContent("Name", value: session.credential?.name ?? "")
                    Text(PairingCopy.notShared).foregroundStyle(.secondary)
                }
                if let push = session.push {
                    Section {
                        NavigationLink("Notifications") {
                            NotificationSettingsView().environmentObject(push)
                        }
                    }
                }
                Section {
                    Button("Un-pair This \(session.kindName)", role: .destructive) { confirmUnpair = true }
                        .disabled(working)
                }
                Section("Advanced") {
                    NavigationLink("Local network (legacy)") { LegacyTransportSettingsView() }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .onAppear { address = session.serverAddress }
            .confirmationDialog("Un-pair this \(session.kindName)?", isPresented: $confirmUnpair, titleVisibility: .visible) {
                Button("Un-pair", role: .destructive) {
                    working = true
                    Task {
                        await session.unpair()
                        working = false
                        dismiss()
                    }
                }
            } message: {
                Text("It will forget Nostromo's content and need to pair again.")
            }
        }
    }

    private func saveAddress() {
        guard let target = EnterCodeView.parse(address: address) else { return }
        session.changeAddress(to: target.host, port: target.port)
    }
}

/// Advanced -> Local network (legacy): the old unauthenticated TCP transport and Bonjour discovery.
private struct LegacyTransportSettingsView: View {
    @EnvironmentObject var session: AppSession
    @State private var legacy = ConnectionSettings.transport == .legacyTCP

    var body: some View {
        Form {
            Section {
                Toggle("Use legacy local-network transport", isOn: $legacy)
                    .onChange(of: legacy) { _, on in session.setTransport(on ? .legacyTCP : .webSocket) }
            } footer: {
                Text("Connects to a Nostromo daemon on your local network by Bonjour, without pairing.")
            }
            if legacy, let store = session.store {
                Section {
                    NavigationLink("Connection Settings") { ConnectionSettingsView(store: store) }
                    NavigationLink("Find on Network") { DaemonDiscoveryView(store: store) }
                }
            }
        }
        .navigationTitle("Local network (legacy)")
        .navigationBarTitleDisplayMode(.inline)
    }
}
