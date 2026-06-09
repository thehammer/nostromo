// NostromoKit — NetworkClient.swift
//
// Network.framework TCP client for nostromd.
//
// Implements the same length-prefixed JSON framing and Hello/Welcome/Subscribe
// handshake used by the macOS Unix-socket client (NostromodClient.swift).
// Uses NWConnection over .tcp for iOS compatibility.
//
// Connection lifecycle:
//   connect() → NWConnection(.tcp) → stateHandler → .ready → sendHello()
//   → readLoop() → dispatch(frame) → messages.send(msg)
//   On disconnect → scheduleReconnect (exponential backoff 1s→30s)

import Foundation
import Network
import Combine
import os

private let log = Logger(subsystem: "com.hammer.nostromo.ios", category: "NetworkClient")

/// Maximum frame body size (4 MiB) — must match the Rust daemon.
private let maxFrameLen: Int = 4 * 1024 * 1024

@MainActor
public final class NetworkClient: ObservableObject {

    // MARK: - Public state

    @Published public private(set) var connected: Bool = false

    /// Decoded server messages delivered on the main actor.
    public let messages = PassthroughSubject<ServerMsg, Never>()

    // MARK: - Configuration

    /// Host (IP or hostname) of the daemon.
    public var host: String {
        didSet { reconnect() }
    }

    /// TCP port of the daemon (default: 47100).
    public var port: UInt16 {
        didSet { reconnect() }
    }

    // MARK: - Private state

    private var connection:     NWConnection?
    private var reconnectDelay: TimeInterval = 1.0
    private let encoder = JSONEncoder()

    private var reconnectTask: Task<Void, Never>?
    private var pingTask:      Task<Void, Never>?

    /// Interval between keepalive pings. NWConnection idles out at ~6s without traffic.
    private let pingInterval: TimeInterval = 3.0

    // MARK: - Init

    public init(host: String = "192.168.1.1", port: UInt16 = 47100) {
        self.host = host
        self.port = port
    }

    // MARK: - Lifecycle

    public func start() {
        log.info("NetworkClient starting — \(self.host, privacy: .public):\(self.port, privacy: .public)")
        openConnection()
    }

    public func stop() {
        pingTask?.cancel()
        pingTask = nil
        reconnectTask?.cancel()
        reconnectTask = nil
        connection?.cancel()
        connection = nil
        connected = false
    }

    private func reconnect() {
        stop()
        openConnection()
    }

    // MARK: - Connection

    private func openConnection() {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let conn = NWConnection(to: endpoint, using: .tcp)
        self.connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.handleState(state)
            }
        }
        conn.start(queue: .global(qos: .utility))
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            log.info("Connected to \(self.host, privacy: .public):\(self.port, privacy: .public)")
            reconnectDelay = 1.0
            sendHello()
            connected = true
            startReading()
            startPinging()

        case .failed(let err):
            log.warning("Connection failed: \(err.localizedDescription, privacy: .public)")
            connected = false
            connection?.cancel()
            connection = nil
            scheduleReconnect()

        case .cancelled:
            connected = false

        default:
            break
        }
    }

    private func scheduleReconnect() {
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30.0)
        log.info("Reconnecting in \(delay, privacy: .public)s")

        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.openConnection()
        }
    }

    // MARK: - Handshake

    private func sendHello() {
        send(ClientHello(clientId: UUID().uuidString, protocolVersion: 4))
        // Phase 0: subscribe to all topics (empty list = "everything").
        send(ClientSubscribe(topics: []))
    }

    // MARK: - Send

    /// Send an encodable message to the daemon. Called by `DaemonStore` and internally.
    func send(_ msg: some Encodable) {
        guard let conn = connection,
              let body = try? encoder.encode(msg)
        else {
            log.debug("send dropped — not connected")
            return
        }

        var bigEndianLen = UInt32(body.count).bigEndian
        var frame = Data(bytes: &bigEndianLen, count: 4)
        frame.append(body)

        conn.send(content: frame, completion: .contentProcessed { [weak self] error in
            if let error {
                let desc = error.localizedDescription
                Task { @MainActor [weak self] in
                    log.warning("send error: \(desc, privacy: .public)")
                    self?.handleDisconnect()
                }
            }
        })
    }

    // MARK: - Frame reading

    /// Kick off the recursive read loop.  Each call reads exactly 4 bytes
    /// (the length prefix), then `length` bytes (the body), then recurses.
    private func startReading() {
        readLength()
    }

    private func readLength() {
        connection?.receive(minimumIncompleteLength: 4, maximumLength: 4) { [weak self] data, _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let error {
                    log.warning("read error: \(error.localizedDescription, privacy: .public)")
                    self.handleDisconnect()
                    return
                }
                guard let data, data.count == 4 else {
                    self.handleDisconnect()
                    return
                }

                let length = Int(data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian })

                guard length > 0, length <= maxFrameLen else {
                    log.error("invalid frame length \(length, privacy: .public)")
                    self.handleDisconnect()
                    return
                }

                self.readBody(length: length)
            }
        }
    }

    private func readBody(length: Int) {
        connection?.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, _, error in
            Task { @MainActor [weak self] in
                guard let self else { return }

                if let error {
                    log.warning("body read error: \(error.localizedDescription, privacy: .public)")
                    self.handleDisconnect()
                    return
                }
                guard let data, data.count == length else {
                    self.handleDisconnect()
                    return
                }

                let msg = ServerMsg.decode(from: data)
                log.debug("← \(data.count, privacy: .public) bytes decoded")
                self.messages.send(msg)

                // Recurse for next frame.
                self.readLength()
            }
        }
    }

    private func handleDisconnect() {
        guard connected else { return }
        log.info("Disconnected — scheduling reconnect")
        pingTask?.cancel()
        pingTask = nil
        connected = false
        connection?.cancel()
        connection = nil
        scheduleReconnect()
    }

    // MARK: - Keepalive

    /// Sends a ping every `pingInterval` seconds to prevent NWConnection idle timeout (~6s).
    private func startPinging() {
        pingTask?.cancel()
        pingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.pingInterval * 1_000_000_000))
                guard !Task.isCancelled, self.connected else { break }
                log.debug("→ ping")
                self.send(ClientPing())
            }
        }
    }
}
