// NostromoKit — WebSocketClient.swift
//
// The phone's transport to a primary `nostromd` (W9/W11): one JSON message per WebSocket text frame
// over `URLSessionWebSocketTask`, authenticated by the device token in an `Authorization: Bearer`
// header. It has the same surface as `NetworkClient` (`connected`, `messages`, `send`, `start`,
// `stop`) and adds `state`, which says why it is not connected.
//
// Lifecycle:
//   start() → connect → send Hello + Subscribe → read frames → publish
//   reconnect: when the client has seen numbered frames it sends `resume` (the last `seq` per topic)
//   in Subscribe, but only once the Welcome lists `"seq"`: a daemon without it is subscribed to
//   exactly as before (W12).
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

/// The only verbs the phone sends over the WebSocket transport. A network peer is read-only: this
/// is the daemon's `NETWORK_ALLOWED` list (`src/ipc/peer.rs`) in wire form, and
/// `tests/ios_policy/test_ios_backplane_policy.py` fails when the two differ. Everything else
/// (approve, answer, Mother actions, the message queue, Perri actions, session send/interrupt,
/// close pane, model set, ...) is dropped before it is encoded onto the socket (B10, Q4, Q7); the
/// daemon would refuse it anyway, so the views hide the controls that would send it (`canMutate`).
public enum OutboundPolicy {
    /// Wire `type` values the WebSocket transport may send (snake_case of the Rust variant names).
    public static let allowedTypes: Set<String> = [
        "activity_snapshot_request",
        "focus_list",
        "hello",
        "model_catalog_request",
        "model_defaults_request",
        "ping",
        "pty_detach",
        "pty_list",
        "session_attach",
        "session_detach",
        "session_list",
        "session_model_get",
        "subscribe",
    ]

    public static func allows(type: String) -> Bool { allowedTypes.contains(type) }
}

@MainActor
public final class WebSocketClient: ObservableObject {

    // MARK: - Public state

    @Published public private(set) var connected: Bool = false
    /// Why the client is (not) connected. Only `.notPaired` means the pairing is gone.
    @Published public private(set) var state: ConnectionState = .connecting
    /// `Welcome.features` from the server: `"ws"`, `"pair"`, `"hosts"`, ...
    @Published public private(set) var serverFeatures: Set<String> = []
    /// The last `seq` seen per topic: what the next Subscribe asks to resume from.
    public var resumePoints: [String: UInt64] { seqTracker.resume }

    /// Decoded server messages, delivered on the main actor.
    public let messages = PassthroughSubject<ServerMsg, Never>()
    /// The same frames with the satellite host each names (W10).
    public let hostedMessages = PassthroughSubject<HostedServerMsg, Never>()

    // MARK: - Configuration

    public var host: String { didSet { if host != oldValue { seqTracker.reset(); restartIfRunning() } } }
    public var port: UInt16 { didSet { if port != oldValue { seqTracker.reset(); restartIfRunning() } } }

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
    /// Survives reconnects (and is cleared when the address changes: another daemon's numbers mean
    /// nothing here).
    private var seqTracker = SeqTracker()

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

    // MARK: - Foreground and refresh

    /// The app came back to the foreground after `backgroundedFor` seconds. A socket that sat in the
    /// background is usually dead without knowing it, so after a while the connection is dropped and
    /// made again at once: the new Subscribe carries `resume`, so what the topics published in the
    /// meantime is replayed (or a `gap` says it cannot be). A short absence changes nothing.
    public func foreground(backgroundedFor: TimeInterval, threshold: TimeInterval = 10) {
        guard runTask != nil, connected, backgroundedFor >= threshold else { return }
        channel?.cancel()
    }

    /// Forget the numbers seen so far without touching the connection: the next Subscribe asks for
    /// nothing to resume. For when what the numbers stood for was wiped (`DaemonStore.wipeAll`): a
    /// resume then would be answered with "covered", and the wiped lists would stay empty until the
    /// next live frame.
    public func resetResume() {
        seqTracker.reset()
    }

    /// Start over without `resume`: the next connection is a fresh subscribe (retained snapshots,
    /// no replay). What a `gap`'s "pull to refresh" does.
    public func refreshNow() {
        seqTracker.reset()
        guard runTask != nil else { return }
        channel?.cancel()
    }

    // MARK: - Send

    /// Sends `msg` as one text frame; drops it when not connected or when `OutboundPolicy` refuses it.
    public func send(_ msg: some Encodable) {
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
        // A host that has no URL fails here, loudly: no token goes anywhere else instead.
        guard let channel = try? WebSocketChannel(host: host, port: port, bearer: credential.token) else {
            return Outcome(failure: .badAddress, wasConnected: false)
        }
        self.channel = channel
        channel.resume()

        // Hello first, then Subscribe, as `NetworkClient` does: every topic, decisions rendered.
        // With numbered frames behind it the client waits for the Welcome before it subscribes, so
        // `resume` goes only to a daemon that lists "seq"; with none it subscribes at once as before.
        let resume = seqTracker.resume
        let hello = ClientHello(clientId: UUID().uuidString, protocolVersion: 4)
        let subscribe = ClientSubscribe(topics: [], rendersDecisions: true)
        guard let helloBody = try? encoder.encode(hello), let subscribeBody = try? encoder.encode(subscribe) else {
            channel.cancel()
            return Outcome(failure: .other, wasConnected: false)
        }
        let subscribeAtOnce = resume.isEmpty
        let sends = Task { [channel] in
            try await channel.send(helloBody)
            if subscribeAtOnce { try await channel.send(subscribeBody) }
        }
        var lateSubscribe: Task<Void, Never>?

        // Nothing answered Hello in time: give up on this socket.
        let deadline = Task { [channel, handshakeTimeout] in
            try? await Task.sleep(nanoseconds: UInt64(handshakeTimeout * 1_000_000_000))
            if !Task.isCancelled { channel.cancel() }
        }
        var pinger: Task<Void, Never>?
        var wasConnected = false
        defer {
            sends.cancel()
            lateSubscribe?.cancel()
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
                if !subscribeAtOnce {
                    // A daemon run other than the one the numbers came from (it restarted) numbers
                    // from 1 again: the tracker drops them here, and the Subscribe asks for nothing
                    // to resume, so the snapshots come back as for a fresh client.
                    seqTracker.observe(data)
                    let sendResume = serverFeatures.contains(SeqWire.feature) ? seqTracker.resume : [:]
                    let body = try? encoder.encode(ClientSubscribe(topics: [], rendersDecisions: true,
                                                                   resume: sendResume,
                                                                   seqEpoch: seqTracker.epoch))
                    lateSubscribe = Task { [channel] in
                        if let body { try? await channel.send(body) }
                    }
                }
                connected = true
                setState(.connected)
                pinger = startPinging(channel)
            }
            // A number skipped where none can be withheld is a loss the daemon did not name.
            if case .jumped(let topic, let from, let to) = seqTracker.observe(data) {
                let skipped = ServerMsg.gap(topic: topic, host: nil, from: from, to: to, reason: .numberJump)
                messages.send(skipped)
                hostedMessages.send(HostedServerMsg(host: nil, msg: skipped))
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
