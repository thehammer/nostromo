import Foundation

// Wire shapes for device administration (daemon <-> the Mac app, over the local Unix socket).
// A device is never described by a credential: `DeviceSummary` has no token field, and an extra
// `token` key on the wire is ignored by the decoder, so it can never be stored or rendered.

struct DeviceSummary: Decodable, Equatable, Identifiable {
    let id: String
    let name: String
    /// `iphone`, `ipad` or `satellite`.
    let kind: String
    let pairedAt: Date
    let lastSeenAt: Date?
    let connected: Bool
    let revokedAt: Date?
    /// `operator`, `device` or `replaced`.
    let revokedBy: String?

    var isRevoked: Bool { revokedAt != nil }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, connected
        case pairedAt = "paired_at", lastSeenAt = "last_seen_at"
        case revokedAt = "revoked_at", revokedBy = "revoked_by"
    }

    init(id: String, name: String, kind: String, pairedAt: Date, lastSeenAt: Date? = nil,
         connected: Bool = false, revokedAt: Date? = nil, revokedBy: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.pairedAt = pairedAt
        self.lastSeenAt = lastSeenAt; self.connected = connected
        self.revokedAt = revokedAt; self.revokedBy = revokedBy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        kind = try c.decode(String.self, forKey: .kind)
        pairedAt = try c.decode(Date.self, forKey: .pairedAt)
        lastSeenAt = try c.decodeIfPresent(Date.self, forKey: .lastSeenAt)
        connected = try c.decodeIfPresent(Bool.self, forKey: .connected) ?? false
        revokedAt = try c.decodeIfPresent(Date.self, forKey: .revokedAt)
        revokedBy = try c.decodeIfPresent(String.self, forKey: .revokedBy)
    }
}

/// `devices`: phones and iPads in `devices` (satellite Macs, in `hosts`, are not shown).
struct DevicesWire: Decodable, Equatable {
    let devices: [DeviceSummary]
    enum CodingKeys: String, CodingKey { case devices }
    init(devices: [DeviceSummary]) { self.devices = devices }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        devices = try c.decodeIfPresent([DeviceSummary].self, forKey: .devices) ?? []
    }
}

struct DevicePairingWire: Decodable, Equatable {
    let requestId: String
    let pairingId: String
    /// Digits only.
    let code: String
    /// `nostromo://pair?v=1&host=<h>&port=<p>&code=<c>`: the primary's address, never this Mac's.
    let serverUrl: String
    let expiresAt: Date
    enum CodingKeys: String, CodingKey {
        case requestId = "request_id", pairingId = "pairing_id", code
        case serverUrl = "server_url", expiresAt = "expires_at"
    }
}

/// How a pairing ended. A value this build does not know decodes as `.unknown` (never an error), so a
/// newer daemon cannot make the whole frame fail and leave the window counting down a dead code.
enum DevicePairOutcomeKind: Decodable, Equatable {
    case paired, expired, cancelled, lockedOut, connectionLost, failed
    case unknown(String)

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "paired": self = .paired
        case "expired": self = .expired
        case "cancelled": self = .cancelled
        case "locked_out": self = .lockedOut
        case "connection_lost": self = .connectionLost
        case "failed": self = .failed
        default: self = .unknown(raw)
        }
    }
}

struct DevicePairOutcomeWire: Decodable, Equatable {
    let pairingId: String
    let outcome: DevicePairOutcomeKind
    let name: String?
    let kind: String?
    let replaced: Bool
    enum CodingKeys: String, CodingKey { case pairingId = "pairing_id", outcome, name, kind, replaced }
    init(pairingId: String, outcome: DevicePairOutcomeKind, name: String? = nil, kind: String? = nil,
         replaced: Bool = false) {
        self.pairingId = pairingId; self.outcome = outcome; self.name = name; self.kind = kind
        self.replaced = replaced
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pairingId = try c.decode(String.self, forKey: .pairingId)
        outcome = try c.decode(DevicePairOutcomeKind.self, forKey: .outcome)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        replaced = try c.decodeIfPresent(Bool.self, forKey: .replaced) ?? false
    }
}

struct DeviceRevokedWire: Decodable, Equatable {
    let requestId: String
    let deviceId: String
    let wasConnected: Bool
    enum CodingKeys: String, CodingKey {
        case requestId = "request_id", deviceId = "device_id", wasConnected = "was_connected"
    }
}

struct DeviceAdminErrorWire: Decodable, Equatable {
    let requestId: String
    /// `server_unreachable`, `not_permitted_on_this_mac`, `unknown_device`, `ambiguous_name`, `not_saved`…
    let reason: String
    enum CodingKeys: String, CodingKey { case requestId = "request_id", reason }
}

/// What this Mac may do on the primary. `level` is one of `full`, `revoke_only`, `read_only`, `off`; any other
/// value is read as read-only by `DeviceAdminModel` (an unknown level never opens a control).
struct DeviceAdminLevelWire: Decodable, Equatable {
    let level: String
    let pairFrom: [String]
    enum CodingKeys: String, CodingKey { case level, pairFrom = "pair_from" }
    init(level: String, pairFrom: [String] = []) { self.level = level; self.pairFrom = pairFrom }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        level = try c.decode(String.self, forKey: .level)
        pairFrom = try c.decodeIfPresent([String].self, forKey: .pairFrom) ?? []
    }
}

// MARK: - Client verbs

struct ClientDevicePairStart: Encodable {
    let type_ = "device_pair_start"
    let requestId: String
    enum CodingKeys: String, CodingKey { case type_ = "type", requestId = "request_id" }
}

struct ClientDevicePairCancel: Encodable {
    let type_ = "device_pair_cancel"
    let requestId: String
    let pairingId: String
    enum CodingKeys: String, CodingKey { case type_ = "type", requestId = "request_id", pairingId = "pairing_id" }
}

struct ClientDeviceList: Encodable {
    let type_ = "device_list"
    let requestId: String
    enum CodingKeys: String, CodingKey { case type_ = "type", requestId = "request_id" }
}

struct ClientDeviceRevoke: Encodable {
    let type_ = "device_revoke"
    let requestId: String
    let device: String
    enum CodingKeys: String, CodingKey { case type_ = "type", requestId = "request_id", device }
}

struct ClientOperatorPresence: Encodable {
    let type_ = "operator_presence"
    let state: String
    enum CodingKeys: String, CodingKey { case type_ = "type", state }
}
