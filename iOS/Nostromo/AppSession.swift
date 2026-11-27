// Nostromo iOS — AppSession.swift
//
// The app's root state: no credential -> Pair with Nostromo; credential -> the tabs over a
// `WebSocketClient`, hydrated from the last-known content; the server says "not paired" -> the
// no-longer-paired screen. It owns the one `DaemonStore` and the Keychain credential.
//
// The one transition with an order that matters is `notPaired` (PRD-AC27, W11-7):
//   1. clear the Keychain credential,
//   2. wipe the store, which empties memory and deletes the cache file,
//   3. only then show the screen.

import SwiftUI
import Combine
import NostromoKit

@MainActor
final class AppSession: ObservableObject, PairingSideEffects {

    enum Phase: Equatable {
        case unpaired
        case paired
        case noLongerPaired
    }

    @Published private(set) var phase: Phase = .unpaired
    @Published private(set) var store: DaemonStore?
    /// Push notifications (W13): present over the WebSocket transport, not the legacy TCP one.
    @Published private(set) var push: PushModel?
    /// A valid `nostromo://pair` link that arrived and has not been used yet.
    @Published var pendingLink: PairLink?
    /// Set when a pairing link was malformed. Nothing was sent.
    @Published var linkError: String?
    /// "Paired as <name>" is up until the first Mother frame arrives, or 1.5 s, whichever is later.
    @Published private(set) var successName: String?
    /// Shown in Settings after an un-pair that could not reach the server.
    @Published private(set) var forgottenNotice: String?

    let credentials: DeviceCredentialStore
    private let cache: ContentCache
    private var client: WebSocketClient?
    private var stateWatch: AnyCancellable?
    private var successTask: Task<Void, Never>?

    var kind: DeviceKindWire { DeviceKindWire.current }
    var kindName: String { kind == .ipad ? "iPad" : "iPhone" }

    init(credentials: DeviceCredentialStore = KeychainDeviceCredentialStore(),
         cache: ContentCache = ContentCache(url: ContentCache.defaultURL())) {
        self.credentials = credentials
        self.cache = cache
        launch()
    }

    // MARK: - Launch

    private func launch() {
        if ConnectionSettings.transport == .legacyTCP {
            let (host, port) = ConnectionSettings.load()
            store = DaemonStore(client: NetworkClient(host: host, port: port))
            phase = .paired
            store?.start()
            return
        }
        // A credential with no saved address (the app was deleted and reinstalled: the Keychain
        // item survives, UserDefaults does not) is deleted here, so no pairing link can ask for it.
        guard let resume = credentials.resumeOrDiscardOrphan(address: ConnectionSettings.lastAddress) else {
            phase = .unpaired
            return
        }
        startPaired(credential: resume.credential, address: resume.address, port: ConnectionSettings.webSocketPort)
    }

    private func startPaired(credential: DeviceCredential, address: String, port: UInt16) {
        let client = WebSocketClient(host: address, port: port, credential: credential)
        let store = DaemonStore(client: client, cache: cache)
        self.client = client
        self.store = store
        // The extension reads the address, the host classes and the "Show full details" switches
        // from the App Group (never a token), and runs only for a device that says it has it.
        let shared = SharedPushState.app
        shared.address = SharedPushState.Address(host: address, port: port)
        let push = PushModel(transport: client, capabilities: PushCapabilitiesWire(nse: true), shared: shared)
        self.push = push
        PushCoordinator.shared.model = push
        stateWatch = client.$state.sink { [weak self] state in
            if case .notPaired = state { self?.handleNotPaired() }
        }
        phase = .paired
        client.start()
    }

    /// The server said this device is not paired (revoked, or a server that never heard of it).
    private func handleNotPaired() {
        guard phase == .paired else { return }
        client?.stop()
        try? credentials.clear()           // 1. the credential
        store?.wipeAll()                   // 2. memory, then the cache file
        store = nil
        push = nil
        PushCoordinator.shared.reset()
        client = nil
        stateWatch = nil
        phase = .noLongerPaired            // 3. the screen
    }

    // MARK: - Foreground

    private var backgroundedAt: Date?

    /// Coming back from the background reconnects (after a while away) with `resume`, so what the
    /// daemon published in the meantime is replayed, or a `gap` says it cannot be (W12).
    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            backgroundedAt = Date()
        case .active:
            if let since = backgroundedAt {
                client?.foreground(backgroundedFor: Date().timeIntervalSince(since))
            }
            backgroundedAt = nil
        default:
            break
        }
    }

    // MARK: - Settings

    var credential: DeviceCredential? { credentials.load() }
    var serverAddress: String { ConnectionSettings.lastAddress ?? "" }

    /// Changing the address keeps the pairing; the same credential reconnects there (PRD-AC33). If
    /// the new address answers "not paired", `handleNotPaired` takes it from there.
    func changeAddress(to address: String, port: UInt16) {
        ConnectionSettings.saveAddress(host: address, webSocketPort: port)
        SharedPushState.app.address = SharedPushState.Address(host: address, port: port)
        client?.host = address
        client?.port = port
    }

    /// Un-pair: ask the server to forget this device if it can be reached, then forget everything
    /// locally either way (PRD-AC31).
    func unpair() async {
        guard let credential = credentials.load() else { return }
        let reached = await DeviceUnpairer.unpair(host: serverAddress, port: ConnectionSettings.webSocketPort,
                                                  credential: credential)
        client?.stop()
        try? credentials.clear()
        store?.wipeAll()
        store = nil
        push = nil
        PushCoordinator.shared.reset()
        client = nil
        stateWatch = nil
        forgottenNotice = reached ? nil : PairingCopy.forgotten(kind: kindName)
        phase = .unpaired
    }

    func setTransport(_ transport: ConnectionSettings.Transport) {
        guard transport != ConnectionSettings.transport else { return }
        client?.stop()
        store?.stop()
        store = nil
        push = nil
        PushCoordinator.shared.reset()
        client = nil
        stateWatch = nil
        ConnectionSettings.transport = transport
        launch()
    }

    // MARK: - Pairing

    func makePairingModel() -> PairingFlowModel {
        PairingFlowModel(kind: kind, credentials: credentials, effects: self) { address, port in
            PairingClient(host: address, port: port)
        }
    }

    /// `nostromo://pair?...`: a valid link goes straight to the confirmation step; a malformed one
    /// shows an error and sends nothing (PRD-AC6, W11-11).
    func handle(url: URL) {
        guard url.scheme?.lowercased() == "nostromo" else { return }
        switch PairLink.parse(url) {
        case .success(let link):
            linkError = nil
            pendingLink = link
        case .failure:
            pendingLink = nil
            linkError = "That isn't a valid Nostromo pairing link."
        }
    }

    func dismissSuccess() { successName = nil }

    // MARK: - PairingSideEffects

    var currentServer: (address: String, port: UInt16)? {
        guard let address = ConnectionSettings.lastAddress else { return nil }
        return (address, ConnectionSettings.webSocketPort)
    }

    func stopCurrentClient() { client?.stop() }
    func restartCurrentClient() { client?.start() }
    func wipeContent() { store?.wipeAll() }

    func unpairFromOldServer(address: String, port: UInt16, credential: DeviceCredential) async {
        _ = await DeviceUnpairer.unpair(host: address, port: port, credential: credential)
    }

    func didPair(_ credential: DeviceCredential, address: String, port: UInt16) {
        client?.stop()
        store?.stop()
        ConnectionSettings.saveAddress(host: address, webSocketPort: port)
        pendingLink = nil
        forgottenNotice = nil
        startPaired(credential: credential, address: address, port: port)
        successName = credential.name
        // Hand over to the tabs once the first Mother frame has arrived, or after 1.5 s, whichever is later.
        successTask?.cancel()
        successTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            while let self, !Task.isCancelled, self.successName != nil {
                if self.store?.motherJobsReceived == true || self.store?.connectionState != .connected { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            self?.successName = nil
        }
    }
}
