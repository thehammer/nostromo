// NostromoKit — PairingWire.swift
//
// Device-pairing and satellite-host frames (W9, W10) as the phone decodes them, plus the hosted
// envelope that carries a frame's optional `host`. Mirrors `src/ipc/protocol.rs` and
// `src/ipc/devices.rs`.

import Foundation

/// Why a pairing code was refused (`PairRefusedReason`).
public enum PairRefusal: String, Equatable {
    case expired
    case invalid
}

/// The device token, held only long enough to put it in the Keychain. It prints as redacted so a
/// log line, a `dump` or a failed assertion never shows it (W11-5).
public struct SecretToken: Equatable, CustomStringConvertible, CustomDebugStringConvertible,
                            CustomReflectable {
    public let value: String
    public init(_ value: String) { self.value = value }
    public var description: String { "Secret(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

/// What a satellite host may do with content (`Egress`). `work` is metadata only.
public enum HostEgress: String, Equatable {
    case work
    case personal
}

/// One connected satellite, as `Hosts` lists it.
public struct HostInfoWire: Equatable {
    public let name: String
    public let egress: HostEgress

    public init(name: String, egress: HostEgress) {
        self.name = name
        self.egress = egress
    }
}

/// Why a routed request could not be sent to a host. Any reason this client does not know is
/// `unavailable`, the same fallback the Rust decoder has (`#[serde(other)]`).
public enum HostUnavailableReason: Equatable {
    case notConnected
    case egressMetadata
    case busy
    case unavailable

    init(wire: String?) {
        switch wire {
        case "not_connected":   self = .notConnected
        case "egress_metadata": self = .egressMetadata
        case "busy":            self = .busy
        default:                self = .unavailable
        }
    }
}

/// A decoded frame and the satellite host it names, if any (`host` is absent for the primary's
/// own state). Kept beside `ServerMsg` so no existing `switch` over `ServerMsg` changes.
public struct HostedServerMsg {
    public let host: String?
    public let msg: ServerMsg
    /// The frame's JSON as it arrived, for the content cache (which keeps only an allow-listed few).
    /// `nil` for a frame built in memory.
    public let raw: Data?

    public init(host: String?, msg: ServerMsg, raw: Data? = nil) {
        self.host = host
        self.msg = msg
        self.raw = raw
    }
}

// MARK: - Decoding

extension ServerMsg {
    private struct PairOfferWrapper: Decodable {
        let name_hint: String?
        let server_id: String
        let challenge: String
        let knows_device: Bool?
    }
    private struct PairedWrapper: Decodable {
        let device_id: String
        let token: String
        let name: String
        let server_id: String
        let replaced: Bool?
    }
    private struct HostsWrapper: Decodable {
        struct Entry: Decodable { let name: String; let egress: String? }
        let hosts: [Entry]
    }

    /// Decodes a frame together with its optional `host`. A frame from a primary that predates W10,
    /// or one about the primary itself, has `host == nil`.
    public static func decodeHosted(from data: Data) -> HostedServerMsg {
        let host = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["host"] as? String
        return HostedServerMsg(host: host, msg: decode(from: data), raw: data)
    }

    /// `Welcome.features` (`"ws"`, `"pair"`, `"hosts"`, ...); empty when the frame has none.
    public static func welcomeFeatures(from data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "welcome" else { return [] }
        return json["features"] as? [String] ?? []
    }

    /// The pairing and host frames; `nil` for any other type string.
    static func decodePairingFrame(type_: String, data: Data) -> ServerMsg? {
        let dec = JSONDecoder()
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        switch type_ {
        case "pair_offer":
            guard let m = try? dec.decode(PairOfferWrapper.self, from: data) else { return .unknown }
            return .pairOffer(nameHint: m.name_hint, serverId: m.server_id,
                              challenge: m.challenge, knowsDevice: m.knows_device)
        case "paired":
            guard let m = try? dec.decode(PairedWrapper.self, from: data) else { return .unknown }
            return .paired(deviceId: m.device_id, token: SecretToken(m.token), name: m.name,
                           serverId: m.server_id, replaced: m.replaced ?? false)
        case "pair_refused":
            // An unknown reason is no more usable than a wrong code.
            let reason = (json?["reason"] as? String).flatMap(PairRefusal.init(rawValue:))
            return .pairRefused(reason ?? .invalid)
        case "unauthorized":
            return .unauthorized(reason: json?["reason"] as? String ?? "")
        case "device_unpaired":
            return .deviceUnpaired
        case "approval_pending":
            guard let tag = json?["tag"] as? String, let count = json?["count"] as? Int else { return .unknown }
            return .approvalPending(tag: tag, count: count)
        case "hosts":
            guard let m = try? dec.decode(HostsWrapper.self, from: data) else { return .unknown }
            return .hosts(m.hosts.map {
                // An unknown or absent egress is the strict one: metadata only.
                HostInfoWire(name: $0.name, egress: $0.egress.flatMap(HostEgress.init(rawValue:)) ?? .work)
            })
        case "host_unavailable":
            guard let host = json?["host"] as? String else { return .unknown }
            return .hostUnavailable(host: host, reason: HostUnavailableReason(wire: json?["reason"] as? String))
        case "gap":
            guard let topic = json?["topic"] as? String,
                  let from = (json?["from"] as? NSNumber)?.uint64Value,
                  let to = (json?["to"] as? NSNumber)?.uint64Value else { return .unknown }
            return .gap(topic: topic, host: json?["host"] as? String, from: from, to: to,
                        reason: GapReason(wire: json?["reason"] as? String))
        default:
            return nil
        }
    }
}
