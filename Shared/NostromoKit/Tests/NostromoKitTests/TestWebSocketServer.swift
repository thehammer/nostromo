// NostromoKit — TestWebSocketServer.swift
//
// Test support for `WebSocketClientTests` and `PairingClientTests`: an in-process WebSocket server
// on the loopback interface (an `NWListener` with `NWProtocolWebSocket` options, port chosen by the
// OS), a fake `LocalNetworkProbing`, and polling helpers with a hard timeout.
//
// Nothing here leaves the machine. The server records what the client does (upgrade headers, text
// frames, how many TCP connections were accepted) and lets a test decide what to answer and when to
// close, so a test asserts on behaviour seen from the daemon's side of the socket.
//
// Limit of the API: `NWProtocolWebSocket.Options.setClientRequestHandler` shows the server the
// request's sub-protocols and its additional headers (Authorization, Origin, ...), not the request
// path, so the path cannot be asserted from here.

import Foundation
import Network
import XCTest
@testable import NostromoKit

// MARK: - Server

final class TestWebSocketServer: @unchecked Sendable {

    /// The upgrade request's headers, as `setClientRequestHandler` reports them.
    struct Handshake {
        let headers: [(name: String, value: String)]

        func value(for name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        var authorization: String? { value(for: "Authorization") }
        var origin: String? { value(for: "Origin") }
    }

    /// One accepted client socket.
    final class Connection: @unchecked Sendable {
        /// 0-based order in which the server accepted it.
        let index: Int
        private let nw: NWConnection
        fileprivate weak var server: TestWebSocketServer?
        private let lock = NSLock()
        private var texts: [String] = []
        private var closed = false

        fileprivate init(index: Int, nw: NWConnection) {
            self.index = index
            self.nw = nw
        }

        /// Every text frame the client sent on this socket, in order.
        var receivedTexts: [String] { locked { texts } }
        /// The client closed the socket (close frame or transport error).
        var isClosed: Bool { locked { closed } }

        /// Sends one text frame to the client.
        func send(_ text: String) {
            let meta = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "text", metadata: [meta])
            nw.send(content: Data(text.utf8), contentContext: context, isComplete: true,
                    completion: .contentProcessed { _ in })
        }

        /// Sends a close frame with `code`.
        func close(code: NWProtocolWebSocket.CloseCode) {
            let meta = NWProtocolWebSocket.Metadata(opcode: .close)
            meta.closeCode = code
            let context = NWConnection.ContentContext(identifier: "close", metadata: [meta])
            nw.send(content: nil, contentContext: context, isComplete: true,
                    completion: .contentProcessed { _ in })
        }

        /// Drops the TCP connection without a close frame.
        func cancel() { nw.cancel() }

        fileprivate func beginReceiving() {
            nw.receiveMessage { [weak self] data, context, _, error in
                guard let self else { return }
                if error != nil { self.markClosed(); return }
                let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata
                switch meta?.opcode {
                case .text?:
                    let text = String(decoding: data ?? Data(), as: UTF8.self)
                    self.locked { self.texts.append(text) }
                    self.server?.textHandler?(self, text)
                case .close?:
                    self.markClosed()
                    return
                default:
                    break
                }
                self.beginReceiving()
            }
        }

        private func markClosed() { locked { closed = true } }

        private func locked<T>(_ body: () -> T) -> T {
            lock.lock(); defer { lock.unlock() }
            return body()
        }
    }

    // MARK: State

    private let listener: NWListener
    private let queue = DispatchQueue(label: "TestWebSocketServer")
    private let lock = NSLock()
    private var _connections: [Connection] = []
    private var _handshakes: [Handshake] = []
    private var _onReady: (@Sendable (Connection) -> Void)?
    private var _onText: (@Sendable (Connection, String) -> Void)?
    private var _stopped = false

    /// Called on the server's queue once a client's upgrade has completed.
    var onReady: (@Sendable (Connection) -> Void)? {
        get { locked { _onReady } }
        set { locked { _onReady = newValue } }
    }
    /// Called on the server's queue for each text frame a client sends.
    var onText: (@Sendable (Connection, String) -> Void)? {
        get { locked { _onText } }
        set { locked { _onText = newValue } }
    }
    fileprivate var textHandler: (@Sendable (Connection, String) -> Void)? { onText }

    /// The loopback port the server listens on (valid once `start` returned).
    var port: UInt16 { listener.port?.rawValue ?? 0 }
    /// TCP connections accepted so far, whether or not their upgrade completed.
    var acceptedConnectionCount: Int { locked { _connections.count } }
    var connections: [Connection] { locked { _connections } }
    /// The upgrade requests seen, in order.
    var handshakes: [Handshake] { locked { _handshakes } }
    var isStopped: Bool { locked { _stopped } }

    func connection(at index: Int) -> Connection? {
        locked { index < _connections.count ? _connections[index] : nil }
    }

    // MARK: Lifecycle

    /// Starts a server on `port` (0: any free port) and returns once it is listening.
    static func start(port: UInt16 = 0,
                      onReady: (@Sendable (Connection) -> Void)? = nil,
                      onText: (@Sendable (Connection, String) -> Void)? = nil) async throws -> TestWebSocketServer {
        let server = try TestWebSocketServer(port: port)
        server.onReady = onReady
        server.onText = onText
        try await server.listen()
        return server
    }

    /// A port nothing listens on: a server is started to learn a free port, then stopped.
    static func unusedPort() async throws -> UInt16 {
        let server = try await start()
        let port = server.port
        await server.stopAndWait()
        return port
    }

    func stop() {
        listener.cancel()
        for connection in connections { connection.cancel() }
    }

    func stopAndWait() async {
        stop()
        let deadline = Date().addingTimeInterval(2)
        while !isStopped && Date() < deadline { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    // MARK: Private

    private init(port: UInt16) throws {
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        parameters.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        let nwPort: NWEndpoint.Port = port == 0 ? .any : (NWEndpoint.Port(rawValue: port) ?? .any)
        listener = try NWListener(using: parameters, on: nwPort)
        ws.setClientRequestHandler(queue) { [weak self] _, headers in
            if let self {
                self.locked { self._handshakes.append(Handshake(headers: headers)) }
            }
            return NWProtocolWebSocket.Response(status: .accept, subprotocol: nil)
        }
    }

    private func listen() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = Gate(continuation)
            listener.newConnectionHandler = { [weak self] nw in self?.accept(nw) }
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    gate.finish(nil)
                case .failed(let error):
                    gate.finish(error)
                    self?.markStopped()
                case .cancelled:
                    gate.finish(CancellationError())
                    self?.markStopped()
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func accept(_ nw: NWConnection) {
        let connection: Connection = locked {
            let made = Connection(index: _connections.count, nw: nw)
            made.server = self
            _connections.append(made)
            return made
        }
        nw.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            if case .ready = state {
                connection.beginReceiving()
                self.onReady?(connection)
            }
        }
        nw.start(queue: queue)
    }

    private func markStopped() { locked { _stopped = true } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body()
    }

    /// Resumes the start-up continuation exactly once.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?
        init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
        func finish(_ error: Error?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            if let error { pending?.resume(throwing: error) } else { pending?.resume() }
        }
    }
}

// MARK: - Fake local-network probe

/// A `LocalNetworkProbing` whose answer a test sets and whose calls it can read.
final class FakeLocalNetworkProbe: LocalNetworkProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var _denied: Bool
    private var _calls: [(host: String, port: UInt16)] = []

    init(denied: Bool = false) { _denied = denied }

    var denied: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _denied }
        set { lock.lock(); defer { lock.unlock() }; _denied = newValue }
    }
    var calls: [(host: String, port: UInt16)] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    func isDenied(host: String, port: UInt16) async -> Bool {
        lock.lock(); defer { lock.unlock() }
        _calls.append((host, port))
        return _denied
    }
}

// MARK: - Polling helpers (hard timeout, never a bare sleep)

/// Polls `condition` every 10 ms until it holds or `timeout` passes; returns whether it held.
@MainActor
func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() >= deadline { return false }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return true
}

/// Fails the test when `condition` does not hold within `timeout`.
@MainActor
func assertEventually(_ message: @autoclosure () -> String, timeout: TimeInterval = 2,
                      file: StaticString = #filePath, line: UInt = #line,
                      _ condition: () -> Bool) async {
    if !(await waitUntil(timeout: timeout, condition)) {
        XCTFail("timed out waiting for: \(message())", file: file, line: line)
    }
}

/// A window in which something must NOT happen. Used only for "does not reconnect" assertions,
/// where absence can only be observed by waiting.
func observationWindow(_ seconds: TimeInterval) async {
    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
}

// MARK: - JSON helpers

/// The top-level object of a JSON text frame; empty when it is not an object.
func parseWireJSON(_ text: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
}

/// The `type` of a JSON text frame.
func wireType(_ text: String) -> String? { parseWireJSON(text)["type"] as? String }
