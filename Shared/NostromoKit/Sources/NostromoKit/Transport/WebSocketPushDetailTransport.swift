// NostromoKit — WebSocketPushDetailTransport.swift
//
// The extension's connection to the primary (W16): a one-shot `URLSessionWebSocketTask` authenticated
// by the device token in the `Authorization` header (never in the URL), `hello`, the `Welcome`, a
// `subscribe` on one narrow topic (the daemon hangs up on a connection whose second frame is anything
// else), `push_detail`, the reply, close. It reads at most `maxFramesRead` frames and `maxBytesRead`
// bytes, each frame at most `PushDetailWire.maxFrameBytes`, skipping the ones it does not care about,
// so a hostile or confused server cannot make it buffer or wait on more than that, and it closes the
// socket when it is cancelled, which is how `PushDetailFetcher`'s deadline ends it.
//
// It cannot bring the WireGuard tunnel up: with the tunnel down the connect simply fails.

import Foundation

public struct WebSocketPushDetailTransport: PushDetailTransport {
    /// Frames read while waiting for the reply: the `Welcome`, the daemon's `withheld` notice and
    /// whatever else it sends every subscriber, skipped. More than that is not an answer.
    static let maxFramesRead = 32
    /// Bytes read in all, however many frames they come in.
    static let maxBytesRead = 128 * 1024

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
            var requested = false
            var frames = 0
            var bytes = 0
            while frames < Self.maxFramesRead, bytes < Self.maxBytesRead {
                let data = try await channel.receive()
                frames += 1
                bytes += data.count
                guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let type = json["type"] as? String else { continue }
                switch type {
                case "welcome" where !requested:
                    requested = true
                    try await channel.send(try encoder.encode(ClientSubscribe.oneShot))
                    try await channel.send(try encoder.encode(ClientPushDetail(itemRef: itemRef)))
                case "push_detail":
                    return data
                case "unauthorized":
                    throw Failure(reason: "unauthorized")
                default:
                    continue
                }
            }
            throw Failure(reason: "no reply")
        } onCancel: {
            channel.cancel()
        }
    }
}
