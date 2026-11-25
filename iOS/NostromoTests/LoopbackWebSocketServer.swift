// L5: an in-process WebSocket server (NWListener, loopback only) that the hosted App Transport
// Security and AppSession tests connect to from inside the app bundle. It lives in this target
// because the Kit test target's server cannot be imported here, and because only a hosted test
// has the app's Info.plist, which is what App Transport Security reads.

import Foundation
import Network

final class LoopbackWebSocketServer: @unchecked Sendable {

    private let listener: NWListener
    private let queue = DispatchQueue(label: "L5LoopbackWebSocketServer")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var _received: [String] = []

    /// Sent to every client as soon as its socket is open.
    private let greeting: String?
    /// The reply to each text frame a client sends (`nil`: no reply).
    private let reply: @Sendable (String) -> String?

    /// The loopback port (valid once `start` returned).
    var port: UInt16 { listener.port?.rawValue ?? 0 }
    /// How many TCP connections the server accepted.
    var acceptedCount: Int { locked { connections.count } }
    /// Every text frame any client sent.
    var receivedTexts: [String] { locked { _received } }

    static func start(greeting: String? = nil,
                      reply: @escaping @Sendable (String) -> String? = { $0 }) async throws -> LoopbackWebSocketServer {
        let server = try LoopbackWebSocketServer(greeting: greeting, reply: reply)
        try await server.listen()
        return server
    }

    func stop() {
        listener.cancel()
        for connection in locked({ connections }) { connection.cancel() }
    }

    // MARK: Private

    private init(greeting: String?, reply: @escaping @Sendable (String) -> String?) throws {
        self.greeting = greeting
        self.reply = reply
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.allowLocalEndpointReuse = true
        parameters.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        listener = try NWListener(using: parameters, on: .any)
        // Accept every upgrade (the handler also reports no client headers, so none can be asserted here).
        ws.setClientRequestHandler(queue) { _, _ in NWProtocolWebSocket.Response(status: .accept, subprotocol: nil) }
    }

    private func listen() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = Gate(continuation)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.finish(nil)
                case .failed(let error): gate.finish(error)
                case .cancelled: gate.finish(CancellationError())
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func accept(_ connection: NWConnection) {
        locked { connections.append(connection) }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, case .ready = state else { return }
            if let greeting = self.greeting { Self.send(greeting, on: connection) }
            self.receive(on: connection)
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, error == nil else { return }
            let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if meta?.opcode == .close { return }
            if meta?.opcode == .text {
                let text = String(decoding: data ?? Data(), as: UTF8.self)
                self.locked { self._received.append(text) }
                if let answer = self.reply(text) { Self.send(answer, on: connection) }
            }
            self.receive(on: connection)
        }
    }

    private static func send(_ text: String, on connection: NWConnection) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [meta])
        connection.send(content: Data(text.utf8), contentContext: context, isComplete: true,
                        completion: .contentProcessed { _ in })
    }

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

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}
