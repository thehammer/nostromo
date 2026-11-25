// NostromoKit — PairingClient.swift
//
// The device half of pairing over a token-less WebSocket (W9): `check` asks whether a code is live
// (and, with a proof, whether the server already knows this device); `pair` redeems it. One socket
// carries both: the daemon binds a verified proof to the socket that sent it, so the proof
// `PairCheck` and a later `Pair { replace: true }` must share it (D6). The socket lives 60 s on the
// daemon and closes after `Pair`.
//
// Nothing here sends the token or its hash; only the HMAC proof over the server's fresh challenge.

import Foundation
import CryptoKit
import os

private let log = Logger(subsystem: "com.hammer.nostromo.ios", category: "PairingClient")

public enum PairingError: Error, Equatable {
    case expired
    case invalid
    case unreachable
    case localNetworkDenied
}

/// The answer to a `PairCheck`.
public struct PairOffer: Equatable {
    public let nameHint: String?
    public let serverId: String
    public let challenge: String
    /// Set only in the answer to the first proof on a code: the server proved it knows this device.
    public let knowsDevice: Bool?
}

/// The answer to a successful `Pair`. The token goes straight into the credential store.
public struct PairedResult: Equatable {
    public let deviceId: String
    public let token: SecretToken
    public let name: String
    public let serverId: String
    public let replaced: Bool
}

@MainActor
public final class PairingClient {
    public let host: String
    public let port: UInt16

    private let probe: LocalNetworkProbing
    private let responseTimeout: TimeInterval
    private var channel: WebSocketChannel?

    public init(host: String, port: UInt16,
                probe: LocalNetworkProbing = NWLocalNetworkProbe(),
                responseTimeout: TimeInterval = 10) {
        self.host = host
        self.port = port
        self.probe = probe
        self.responseTimeout = responseTimeout
    }

    /// Whether a pairing socket is currently held (the caller may need to re-check, with a fresh
    /// proof, before `Pair { replace: true }` if the 60 s socket has gone).
    public var isOpen: Bool { channel != nil }

    /// `HMAC-SHA256(key: SHA-256(token), message: challenge ‖ code)`, base64url without padding.
    /// The encoding is pinned by W9's `the_proof_encoding_is_pinned_by_a_fixed_vector`.
    public nonisolated static func proof(token: String, challenge: String, code: String) -> String {
        let key = SymmetricKey(data: SHA256.hash(data: Data(token.utf8)))
        let message = Data((challenge + Self.digits(code)).utf8)
        let mac = HMAC<SHA256>.authenticationCode(for: message, using: key)
        return Data(mac).base64URLEncodedNoPadding
    }

    /// Asks whether `code` is live. Never uses the code up.
    public func check(code: String, proof: String? = nil) async throws -> PairOffer {
        let reply = try await exchange(ClientPairCheck(code: Self.digits(code), proof: proof))
        switch reply {
        case .pairOffer(let nameHint, let serverId, let challenge, let knowsDevice):
            return PairOffer(nameHint: nameHint, serverId: serverId, challenge: challenge, knowsDevice: knowsDevice)
        case .pairRefused(let reason):
            throw reason == .expired ? PairingError.expired : PairingError.invalid
        default:
            throw PairingError.unreachable
        }
    }

    /// Redeems `code`. The daemon closes the socket after answering, so this one is done either way.
    public func pair(code: String, name: String, kind: DeviceKindWire, replace: Bool) async throws -> PairedResult {
        defer { close() }
        let reply = try await exchange(ClientPair(code: Self.digits(code), name: name, kind: kind, replace: replace))
        switch reply {
        case .paired(let deviceId, let token, let name, let serverId, let replaced):
            return PairedResult(deviceId: deviceId, token: token, name: name, serverId: serverId, replaced: replaced)
        case .pairRefused(let reason):
            throw reason == .expired ? PairingError.expired : PairingError.invalid
        default:
            throw PairingError.unreachable
        }
    }

    public func close() {
        channel?.cancel()
        channel = nil
    }

    // MARK: - Private

    private nonisolated static func digits(_ code: String) -> String {
        String(code.filter { $0.isASCII && $0.isNumber })
    }

    /// Sends one request and returns the next frame the daemon answers with.
    private func exchange(_ request: some Encodable) async throws -> ServerMsg {
        let channel = openIfNeeded()
        do {
            let body = try JSONEncoder().encode(request)
            let timeout = responseTimeout
            return try await withDeadline(timeout) {
                try await channel.send(body)
                while true {
                    let frame = ServerMsg.decode(from: try await channel.receive())
                    // The pairing socket may greet before it answers; only an answer is returned.
                    switch frame {
                    case .welcome, .unknown, .pong: continue
                    default: return frame
                    }
                }
            }
        } catch {
            let failure = (error is TimeoutError) ? ConnectionFailure.transport(.timedOut)
                                                  : channel.failure(for: error)
            close()
            let refined = await probe.refine(failure, host: host, port: port)
            log.info("pairing socket failed: \(String(describing: refined), privacy: .public)")
            throw refined == .localNetworkDenied ? PairingError.localNetworkDenied : PairingError.unreachable
        }
    }

    private func openIfNeeded() -> WebSocketChannel {
        if let channel { return channel }
        let fresh = WebSocketChannel(host: host, port: port, bearer: nil)
        fresh.resume()
        channel = fresh
        return fresh
    }
}

extension Data {
    /// base64url, no padding (RFC 4648 §5), the encoding the daemon uses for tokens and proofs.
    var base64URLEncodedNoPadding: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
