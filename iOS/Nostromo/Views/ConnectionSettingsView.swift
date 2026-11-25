// Nostromo iOS — ConnectionSettingsView.swift
//
// Manual host:port entry.  Stores settings in UserDefaults and passes them
// to NetworkClient when the user taps Connect.
//
// Phase 0 only: replaced by Bonjour/DNS-SD discovery in Phase 5.

import SwiftUI
import NostromoKit

/// UserDefaults-backed connection settings. `host` is the last address used and is never cleared by
/// a revoke or an un-pair (PRD-AC32); it is the only pairing-related thing kept in UserDefaults:
/// the token lives in the Keychain.
enum ConnectionSettings {
    private static let hostKey = "nostromd.host"
    private static let portKey = "nostromd.port"
    private static let wsPortKey = "nostromd.ws.port"
    private static let transportKey = "nostromd.transport"

    enum Transport: String {
        case webSocket
        case legacyTCP
    }

    static let defaultWebSocketPort: UInt16 = 47101

    /// Which transport the app uses. `.legacyTCP` is only reachable from Settings → Advanced.
    static var transport: Transport {
        get { Transport(rawValue: UserDefaults.standard.string(forKey: transportKey) ?? "") ?? .webSocket }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: transportKey) }
    }

    /// The last server address used, or `nil` if there never was one.
    static var lastAddress: String? { UserDefaults.standard.string(forKey: hostKey) }

    static var webSocketPort: UInt16 {
        let port = UInt16(truncatingIfNeeded: UserDefaults.standard.integer(forKey: wsPortKey))
        return port == 0 ? defaultWebSocketPort : port
    }

    static func saveAddress(host: String, webSocketPort: UInt16) {
        UserDefaults.standard.set(host, forKey: hostKey)
        UserDefaults.standard.set(Int(webSocketPort), forKey: wsPortKey)
    }

    static let defaultHost = "192.168.1.1"
    static let defaultPort: UInt16 = 47100

    /// Returns `true` if the user has never customised the host.
    static var isDefault: Bool {
        UserDefaults.standard.string(forKey: hostKey) == nil
    }

    static func load() -> (host: String, port: UInt16) {
        let host = UserDefaults.standard.string(forKey: hostKey) ?? defaultHost
        let port = UInt16(UserDefaults.standard.integer(forKey: portKey))
        return (host, port == 0 ? defaultPort : port)
    }

    static func save(host: String, port: UInt16) {
        UserDefaults.standard.set(host, forKey: hostKey)
        UserDefaults.standard.set(Int(port), forKey: portKey)
    }
}

struct ConnectionSettingsView: View {
    let store: DaemonStore

    @Environment(\.dismiss) private var dismiss

    @State private var hostText: String
    @State private var portText: String
    @State private var errorMsg: String?

    init(store: DaemonStore) {
        self.store = store
        let (host, port) = ConnectionSettings.load()
        _hostText = State(initialValue: host)
        _portText = State(initialValue: String(port))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Host") {
                        TextField("192.168.1.100", text: $hostText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .multilineTextAlignment(.trailing)
                    }

                    LabeledContent("Port") {
                        TextField("47100", text: $portText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("Daemon Connection")
                } footer: {
                    Text("Discovery normally finds nostromd automatically. Enter a host manually only if your network blocks Bonjour. Use the Mac's `.local` name (e.g. `hostname.local`) or its LAN IP. Default port is 47100.")
                }

                if let errorMsg {
                    Section {
                        Label(errorMsg, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Connection Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") { connect() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private func connect() {
        let host = hostText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            errorMsg = "Please enter a host address."
            return
        }
        guard let portVal = UInt16(portText.trimmingCharacters(in: .whitespacesAndNewlines)),
              portVal > 0
        else {
            errorMsg = "Port must be a number between 1 and 65535."
            return
        }

        ConnectionSettings.save(host: host, port: portVal)
        store.legacyClient?.host = host
        store.legacyClient?.port = portVal

        dismiss()
    }
}

#Preview {
    ConnectionSettingsView(store: {
        let client = NetworkClient(host: "127.0.0.1", port: 47100)
        return DaemonStore(client: client)
    }())
}
