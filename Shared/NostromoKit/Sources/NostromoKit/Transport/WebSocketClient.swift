// NostromoKit — WebSocketClient.swift
//
// The phone's transport to a primary `nostromd` (W9/W11): one JSON message per WebSocket text frame
// over `URLSessionWebSocketTask`, authenticated by the device token in an `Authorization: Bearer`
// header. It has the same surface as `NetworkClient` (`connected`, `messages`, `send`, `start`,
// `stop`) and adds `state`, which says why it is not connected.
//
// Lifecycle:
//   start() → connect → send Hello + Subscribe → read frames → publish
//   any failure → classify (`ConnectionFailure.state`) → back off 1 s → 30 s → connect again
//   `Unauthorized` frame or close code 4001 → `.notPaired`, and stop: a revoked token will not come
//   back, so reconnecting would only hammer the daemon.
//
// The phone never answers or changes anything over this transport: `OutboundPolicy` drops those
// verbs before they are encoded onto the socket (B10, Q4, Q7).

import Foundation
import Combine
import os

private let log = Logger(subsystem: "com.hammer.nostromo.ios", category: "WebSocketClient")

/// Which verbs the phone refuses to send. Everything the phone does send is read-only:
/// subscribe, list, attach, snapshot, model get.
public enum OutboundPolicy {
    /// Wire `type` values the WebSocket transport never sends.
    public static let refusedTypes: Set<String> = [
        "approval_answer",           // B10: no approve/deny anywhere on iOS
        "decision_answer",           // Q4: decisions are read-only on the phone
        "mother_resume",             // B10: no answering a held Mother job
        "mother_action",             // B10: no cancel/retry/force-start
        "session_queue_watch",       // D7, Q7: the phone shows nothing from the message queue
        "session_queue_take_back",
        "session_queue_remove",
    ]

    public static func allows(type: String) -> Bool { !refusedTypes.contains(type) }
}

@MainActor
public final class WebSocketClient: ObservableObject {

    // MARK: - Public state

    @Published public private(set) var connected: Bool = false
    /// Why the client is (not) connected. Only `.notPaired` means the pairing is gone.
    @Published public private(set) var state: ConnectionState = .connecting
    /// `Welcome.features` from the server: `"ws"`, `"pair"`, `"hosts"`, ...
    @Published public private(set) var serverFeatures: Set<String> = []

    /// Decoded server messages, delivered on the main actor.
    public let messages = PassthroughSubject<ServerMsg, Never>()
    /// The same frames with the satellite host each names (W10).
    public let hostedMessages = PassthroughSubject<HostedServerMsg, Never>()

    // MARK: - Configuration

    public var host: String { didSet { if host != oldValue { restartIfRunning() } } }
    public var port: UInt16 { didSet { if port != oldValue { restartIfRunning() } } }

    // MARK: - Private state

    private let credential: DeviceCredential
    private let probe: LocalNetworkProbing
    private let initialBackoff: TimeInterval
    private let maxBackoff: TimeInterval
    private let pingInterval: TimeInterval
    private let handshakeTimeout: TimeInterval

    private var runTask: Task<Void, Never>?
    private var channel: WebSocketChannel?
    private let encoder = JSONEncoder()

    // MARK: - Init

    public init(host: String, port: UInt16 = 47101, credential: DeviceCredential,
                probe: LocalNetworkProbing = NWLocalNetworkProbe(),
                initialBackoff: TimeInterval = 1, maxBackoff: TimeInterval = 30,
                pingInterval: TimeInterval = 20, handshakeTimeout: TimeInterval = 10) {
        self.host = host
        self.port = port
        self.credential = credential
        self.probe = probe
        self.initialBackoff = initialBackoff
        self.maxBackoff = maxBackoff
        self.pingInterval = pingInterval
        self.handshakeTimeout = handshakeTimeout
    }

    // MARK: - Lifecycle

    public func start() {
        guard runTask == nil else { return }
        log.info("WebSocketClient starting: \(self.host, privacy: .public):\(self.port, privacy: .public)")
        setState(.connecting)
        runTask = Task { [weak self] in await self?.run() }
    }

    public func stop() {
        runTask?.cancel()
        runTask = nil
        channel?.cancel()
        channel = nil
        connected = false
    }

    // MARK: - Send

    /// Sends `msg` as one text frame; drops it when not connected or when `OutboundPolicy` refuses it.
    func send(_ msg: some Encodable) {
        guard let body = encodeForSend(msg), let channel else {
            log.debug("send dropped: not connected or refused")
            return
        }
        Task {
            // A failed send is seen again by the read loop, which reconnects; only log it here.
            do { try await channel.send(body) } catch {
                log.warning("send failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The frame bytes for `msg`, or `nil` when the policy refuses to send that verb.
    func encodeForSend(_ msg: some Encodable) -> Data? {
        guard let body = try? encoder.encode(msg) else { return nil }
        let type = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["type"] as? String
        guard let type, OutboundPolicy.allows(type: type) else { return nil }
        return body
    }

    // MARK: - Connection loop

    private func restartIfRunning() {
        guard runTask != nil else { return }
        stop()
        start()
    }

    private func run() async {
        var backoff = initialBackoff
        while !Task.isCancelled {
            let outcome = await connectOnce()
            if Task.isCancelled { return }
            connected = false
            channel = nil

            let failure = await probe.refine(outcome.failure, host: host, port: port)
            let next = failure.state
            setState(next)
            if case .notPaired = next {
                // The server said this device is not paired. Do not reconnect.
                runTask = nil
                return
            }
            if outcome.wasConnected { backoff = initialBackoff }
            try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
            backoff = min(backoff * 2, maxBackoff)
        }
    }

    private struct Outcome {
        let failure: ConnectionFailure
        let wasConnected: Bool
    }

    /// One connection, from the upgrade to its end.
    private func connectOnce() async -> Outcome {
        let channel = WebSocketChannel(host: host, port: port, bearer: credential.token)
        self.channel = channel
        channel.resume()

        // Hello first, then Subscribe, as `NetworkClient` does: every topic, decisions rendered.
        let hello = ClientHello(clientId: UUID().uuidString, protocolVersion: 4)
        let subscribe = ClientSubscribe(topics: [], rendersDecisions: true)
        guard let helloBody = try? encoder.encode(hello), let subscribeBody = try? encoder.encode(subscribe) else {
            channel.cancel()
            return Outcome(failure: .other, wasConnected: false)
        }
        let sends = Task { [channel] in
            try await channel.send(helloBody)
            try await channel.send(subscribeBody)
        }

        // Nothing answered Hello in time: give up on this socket.
        let deadline = Task { [channel, handshakeTimeout] in
            try? await Task.sleep(nanoseconds: UInt64(handshakeTimeout * 1_000_000_000))
            if !Task.isCancelled { channel.cancel() }
        }
        var pinger: Task<Void, Never>?
        var wasConnected = false
        defer {
            sends.cancel()
            deadline.cancel()
            pinger?.cancel()
            channel.cancel()
        }

        while !Task.isCancelled {
            let data: Data
            do { data = try await channel.receive() } catch {
                return Outcome(failure: channel.failure(for: error), wasConnected: wasConnected)
            }
            let hosted = ServerMsg.decodeHosted(from: data)
            if case .unauthorized(let reason) = hosted.msg {
                return Outcome(failure: .unauthorizedFrame(reason: reason), wasConnected: wasConnected)
            }
            if !wasConnected {
                wasConnected = true
                deadline.cancel()
                serverFeatures = Set(ServerMsg.welcomeFeatures(from: data))
                connected = true
                setState(.connected)
                pinger = startPinging(channel)
            }
            messages.send(hosted.msg)
            hostedMessages.send(hosted)
        }
        return Outcome(failure: .other, wasConnected: wasConnected)
    }

    /// A WebSocket ping every `pingInterval`; a failed ping ends the read loop through the channel.
    private func startPinging(_ channel: WebSocketChannel) -> Task<Void, Never> {
        Task { [pingInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(pingInterval * 1_000_000_000))
                if Task.isCancelled { return }
                do { try await channel.sendPing() } catch {
                    channel.cancel()
                    return
                }
            }
        }
    }

    private func setState(_ new: ConnectionState) {
        if state != new { state = new }
        if case .connected = new {} else { connected = false }
    }
}
