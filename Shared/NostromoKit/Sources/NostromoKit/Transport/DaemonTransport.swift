// NostromoKit — DaemonTransport.swift
//
// What `DaemonStore` and `TranscriptStore` need from a connection to nostromd, so the WebSocket
// client (the app's transport) and the legacy TCP `NetworkClient` (Settings → Advanced → Local
// network) are interchangeable behind them.

import Foundation
import Combine

@MainActor
public protocol DaemonTransport: AnyObject {
    var connected: Bool { get }
    var connectedPublisher: AnyPublisher<Bool, Never> { get }
    /// Every decoded frame with the satellite host it names (`nil` for the primary's own).
    var framePublisher: AnyPublisher<HostedServerMsg, Never> { get }
    /// Why the link is up or down. The legacy client can only say connected or connecting.
    var connectionStatePublisher: AnyPublisher<ConnectionState, Never> { get }
    func start()
    func stop()
    func send(_ msg: some Encodable)
    /// Whether this link may carry anything that changes state on the Mac (answer, approve, send,
    /// cancel...). The WebSocket transport cannot (`OutboundPolicy`), so views hide those controls.
    var canMutate: Bool { get }
    /// Start the subscription over without resuming (the "pull to refresh" after a `gap`). A
    /// transport with nothing to resume from does nothing.
    func refreshNow()
}

extension DaemonTransport {
    public func refreshNow() {}

    /// Fails safe: a transport says so explicitly to be allowed to mutate.
    public var canMutate: Bool { false }
}

extension NetworkClient: DaemonTransport {
    public var canMutate: Bool { true }

    public var connectedPublisher: AnyPublisher<Bool, Never> { $connected.eraseToAnyPublisher() }

    public var framePublisher: AnyPublisher<HostedServerMsg, Never> {
        messages.map { HostedServerMsg(host: nil, msg: $0) }.eraseToAnyPublisher()
    }

    public var connectionStatePublisher: AnyPublisher<ConnectionState, Never> {
        $connected.map { $0 ? ConnectionState.connected : .connecting }.eraseToAnyPublisher()
    }
}

extension WebSocketClient: DaemonTransport {
    public var canMutate: Bool { false }

    public var connectedPublisher: AnyPublisher<Bool, Never> { $connected.eraseToAnyPublisher() }
    public var framePublisher: AnyPublisher<HostedServerMsg, Never> { hostedMessages.eraseToAnyPublisher() }
    public var connectionStatePublisher: AnyPublisher<ConnectionState, Never> { $state.eraseToAnyPublisher() }
}
