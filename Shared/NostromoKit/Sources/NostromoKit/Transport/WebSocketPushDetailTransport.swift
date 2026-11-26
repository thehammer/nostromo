// NostromoKit — WebSocketPushDetailTransport.swift
//
// The extension's connection to the primary (W16): a one-shot `URLSessionWebSocketTask` authenticated
// by the device token in the `Authorization` header (never in the URL), `hello`, `push_detail`, the
// reply, close. It reads at most a handful of frames of at most `PushDetailWire.maxFrameBytes` each,
// so a hostile or confused server cannot make it buffer or wait on more than that, and it closes the
// socket when it is cancelled, which is how `PushDetailFetcher`'s deadline ends it.
//
// It cannot bring the WireGuard tunnel up: with the tunnel down the connect simply fails.

import Foundation

public struct WebSocketPushDetailTransport: PushDetailTransport {
    /// Frames read while waiting for the reply: the `Welcome` and a few pushes sent first.
    static let maxFramesRead = 8

    public struct Failure: Error, Equatable {
        public let reason: String
    }

    private let host: String
    private let port: UInt16
    private let token: String

    public init(host: String, port: UInt16, token: String) {
        self.host = host
        self.port = port
        self.token = token
    }

    public func request(itemRef: String) async throws -> Data {
        let channel = try WebSocketChannel(host: host, port: port, bearer: token,
                                           maximumMessageSize: PushDetailWire.maxFrameBytes)
        return try await withTaskCancellationHandler {
            channel.resume()
            defer { channel.cancel() }
            let encoder = JSONEncoder()
            try await channel.send(try encoder.encode(ClientHello(clientId: UUID().uuidString, protocolVersion: 4, capabilities: [])))
            try await channel.send(try encoder.encode(ClientPushDetail(itemRef: itemRef)))
            for _ in 0..<Self.maxFramesRead {
                let data = try await channel.receive()
                guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let type = json["type"] as? String else { continue }
                if type == "push_detail" { return data }
                if type == "unauthorized" { throw Failure(reason: "unauthorized") }
            }
            throw Failure(reason: "no reply")
        } onCancel: {
            channel.cancel()
        }
    }
}
