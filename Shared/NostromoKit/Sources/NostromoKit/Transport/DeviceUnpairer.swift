// NostromoKit — DeviceUnpairer.swift
//
// Asks a server to forget this device: a short authenticated socket, `Hello`, then
// `DeviceUnpairSelf`, and wait for `DeviceUnpaired`. Used by Settings → Un-pair and by pairing with a
// different server (D6). The caller decides what to do about "no": an unreachable server just means
// its entry goes stale until the operator revokes it from the Devices list.

import Foundation

public enum DeviceUnpairer {

    /// Returns `true` only if the server answered `DeviceUnpaired` within `timeout`.
    public static func unpair(host: String, port: UInt16, credential: DeviceCredential,
                              timeout: TimeInterval = 5) async -> Bool {
        guard let channel = try? WebSocketChannel(host: host, port: port, bearer: credential.token) else { return false }
        defer { channel.cancel() }
        channel.resume()
        do {
            return try await withDeadline(timeout) {
                let encoder = JSONEncoder()
                try await channel.send(try encoder.encode(ClientHello(clientId: UUID().uuidString, protocolVersion: 4)))
                try await channel.send(try encoder.encode(ClientDeviceUnpairSelf()))
                while true {
                    switch ServerMsg.decode(from: try await channel.receive()) {
                    case .deviceUnpaired: return true
                    case .unauthorized: return false
                    default: continue
                    }
                }
            }
        } catch {
            return false
        }
    }
}
