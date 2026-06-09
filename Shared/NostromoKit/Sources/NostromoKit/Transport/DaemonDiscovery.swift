// NostromoKit — DaemonDiscovery.swift
//
// NWBrowser-backed Bonjour discovery for _nostromo._tcp services.
//
// Usage:
//   let discovery = DaemonDiscovery()
//   discovery.start()
//   // Observe `discovery.state` or `discovery.daemons` for results.
//
// The state machine progresses: .idle → .browsing → .found([...]) | .none
// ".none" is reached when the browse timeout expires with no results.

import Foundation
import Network
import os

private let log = Logger(subsystem: "com.hammer.nostromo.kit", category: "DaemonDiscovery")

// MARK: - DiscoveryState

/// The current state of the Bonjour browse operation.
public enum DiscoveryState: Equatable {
    /// Not yet started.
    case idle
    /// Browse is active; no daemons found yet.
    case browsing
    /// One or more daemons have been found.
    case found([DiscoveredDaemon])
    /// Browse timed out with no results.
    case none
}

// MARK: - DiscoveredDaemon

/// A nostromd daemon discovered via Bonjour.
public struct DiscoveredDaemon: Identifiable, Equatable {
    /// Stable string identity derived from the endpoint (service name).
    public let id: String

    /// Human-readable instance name (e.g. `hammers-macbook-pro`).
    public let name: String

    /// Resolvable `.local` hostname (e.g. `hammers-macbook-pro.local`).
    /// `NWConnection` resolves `.local` names via mDNS natively, so this
    /// can be passed directly to `NetworkClient.host`.
    public let hostName: String

    /// The underlying browse-result endpoint.  Connecting directly via this
    /// endpoint lets Network.framework use the browse result for resolution,
    /// which is more reliable on some networks than resolving `.local` from
    /// scratch.
    public let endpoint: NWEndpoint

    public static func == (lhs: DiscoveredDaemon, rhs: DiscoveredDaemon) -> Bool {
        lhs.id == rhs.id
    }

    /// Derive a `DiscoveredDaemon` from a Bonjour service endpoint.
    ///
    /// Returns `nil` for non-service endpoints (e.g. `.hostPort`).
    /// The hostname is derived from the service name: the daemon advertises
    /// its machine hostname as the Bonjour instance name, so
    /// `<name>.local` is the resolvable host.
    static func from(endpoint: NWEndpoint) -> DiscoveredDaemon? {
        guard case .service(let name, _, _, _) = endpoint else { return nil }
        let hostName = deriveHostName(from: name)
        return DiscoveredDaemon(
            id:       name,
            name:     name,
            hostName: hostName,
            endpoint: endpoint
        )
    }

    /// Derive the `.local` host name from the Bonjour instance name.
    ///
    /// Strips a trailing `.local` suffix from the service name if present,
    /// then appends `.local`, so the result is always of the form
    /// `<basename>.local`.
    public static func deriveHostName(from serviceName: String) -> String {
        let base = serviceName.hasSuffix(".local")
            ? String(serviceName.dropLast(".local".count))
            : serviceName
        return "\(base).local"
    }
}

// MARK: - DaemonDiscovery

/// Discovers `_nostromo._tcp` Bonjour services on the local network.
///
/// Conforms to `ObservableObject` for SwiftUI integration.  All published
/// updates are delivered on the main actor.
@MainActor
public final class DaemonDiscovery: ObservableObject {

    // MARK: Public state

    /// All daemons discovered so far in the current browse session.
    @Published public private(set) var daemons: [DiscoveredDaemon] = []

    /// Current browse state.
    @Published public private(set) var state: DiscoveryState = .idle

    // MARK: Configuration

    /// How long to wait after the first result before auto-connecting
    /// (callers use this to decide single-daemon auto-connect).
    public let settleInterval: TimeInterval

    /// How long to wait after `start()` before transitioning to `.none`
    /// if no daemons have been found.
    public let timeout: TimeInterval

    // MARK: Private

    private var browser:     NWBrowser?
    private var timeoutTask: Task<Void, Never>?

    private let browseQueue = DispatchQueue(
        label: "com.hammer.nostromo.kit.DaemonDiscovery",
        qos: .utility
    )

    // MARK: Init

    public init(settleInterval: TimeInterval = 1.5, timeout: TimeInterval = 2.0) {
        self.settleInterval = settleInterval
        self.timeout        = timeout
    }

    // MARK: - Public API

    /// Start browsing for `_nostromo._tcp` services.
    ///
    /// Cancels any previous browse session first.  Automatically transitions
    /// to `.none` if nothing is found within `timeout` seconds.
    public func start() {
        stop()
        daemons = []
        state   = .browsing
        log.info("DaemonDiscovery: starting browse")

        let params = NWParameters.tcp
        let browser = NWBrowser(
            for: .bonjour(type: "_nostromo._tcp", domain: nil),
            using: params
        )
        self.browser = browser

        browser.browseResultsChangedHandler = { [weak self] results, changes in
            let endpoints = results.map(\.endpoint)
            Task { @MainActor [weak self] in
                self?.handleResults(endpoints)
            }
        }

        browser.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleBrowserState(state)
            }
        }

        browser.start(queue: browseQueue)

        // Schedule timeout — transitions to .none if still empty.
        timeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.timeout * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if self.daemons.isEmpty {
                log.info("DaemonDiscovery: timeout — no daemons found")
                self.state = .none
            }
        }
    }

    /// Stop the current browse session.
    public func stop() {
        timeoutTask?.cancel()
        timeoutTask = nil
        browser?.cancel()
        browser = nil
        log.debug("DaemonDiscovery: stopped")
    }

    // MARK: - Private

    private func handleResults(_ endpoints: [NWEndpoint]) {
        // Map each endpoint to a DiscoveredDaemon, deduplicating by name.
        var seen   = Set<String>()
        let fresh  = endpoints.compactMap { DiscoveredDaemon.from(endpoint: $0) }
            .filter { seen.insert($0.id).inserted }

        guard !fresh.isEmpty else { return }

        // Merge with any previously seen daemons (browser may report subsets).
        var merged = daemons
        for daemon in fresh {
            if !merged.contains(where: { $0.id == daemon.id }) {
                merged.append(daemon)
            }
        }
        daemons = merged
        state   = .found(merged)
        log.info("DaemonDiscovery: found \(merged.count, privacy: .public) daemon(s)")
    }

    private func handleBrowserState(_ state: NWBrowser.State) {
        switch state {
        case .failed(let error):
            log.error("DaemonDiscovery: browser failed: \(error.localizedDescription, privacy: .public)")
            self.state = .none
        case .cancelled:
            log.debug("DaemonDiscovery: browser cancelled")
        default:
            break
        }
    }
}
