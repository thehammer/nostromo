// NostromoKit — PushWire.swift
//
// The push messages (W13): what the phone sends the primary to register for notifications and to
// set them up, and what the primary answers. Mirrors `src/push/wire.rs` and the `RegisterPush`,
// `SetPushPrefs`, `PushSentLog` and `PushWaiting` verbs and the `PushSentLog`, `PushWaiting` and
// `PushStatus` frames in `src/ipc/protocol.rs`.
//
// The four verbs are a paired phone's, scoped to its own device record (`OutboundPolicy.pairedDeviceTypes`).
// Host classes and work owners arrive read-only: there is no message that changes them.

import Foundation

// MARK: - Settings

public enum PushKindWire: String, Codable, Equatable, Sendable, CaseIterable {
    case mother, decision, review
}

public struct PushKindsWire: Codable, Equatable, Sendable {
    public var mother: Bool
    public var decision: Bool
    public var review: Bool

    public init(mother: Bool = true, decision: Bool = true, review: Bool = true) {
        self.mother = mother
        self.decision = decision
        self.review = review
    }

    public func enabled(_ kind: PushKindWire) -> Bool {
        switch kind {
        case .mother: return mother
        case .decision: return decision
        case .review: return review
        }
    }

    public mutating func set(_ kind: PushKindWire, to value: Bool) {
        switch kind {
        case .mother: mother = value
        case .decision: decision = value
        case .review: review = value
        }
    }
}

/// `HH:MM` quiet hours in the phone's local time. Off keeps the times: the morning digest still
/// fires at `end`.
public struct PushQuietWire: Codable, Equatable, Sendable {
    public var start: String
    public var end: String
    public var enabled: Bool

    public init(start: String = "22:00", end: String = "07:00", enabled: Bool = true) {
        self.start = start
        self.end = end
        self.enabled = enabled
    }
}

public struct PushPrefsWire: Codable, Equatable, Sendable {
    public var kinds: PushKindsWire
    public var quiet: PushQuietWire
    /// `HH:MM`; `nil` turns the evening summary off.
    public var eveningSummary: String?
    /// An IANA zone name.
    public var tz: String

    public static let `default` = PushPrefsWire()

    public init(kinds: PushKindsWire = PushKindsWire(), quiet: PushQuietWire = PushQuietWire(),
                eveningSummary: String? = "17:30", tz: String = TimeZone.current.identifier) {
        self.kinds = kinds
        self.quiet = quiet
        self.eveningSummary = eveningSummary
        self.tz = tz
    }

    enum CodingKeys: String, CodingKey {
        case kinds, quiet, tz
        case eveningSummary = "evening_summary"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kinds = try c.decodeIfPresent(PushKindsWire.self, forKey: .kinds) ?? PushKindsWire()
        quiet = try c.decodeIfPresent(PushQuietWire.self, forKey: .quiet) ?? PushQuietWire()
        // Absent means the default; an explicit null means off (the daemon's `Option<String>`).
        eveningSummary = c.contains(.eveningSummary)
            ? try c.decodeIfPresent(String.self, forKey: .eveningSummary)
            : "17:30"
        tz = try c.decodeIfPresent(String.self, forKey: .tz) ?? "UTC"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kinds, forKey: .kinds)
        try c.encode(quiet, forKey: .quiet)
        // An explicit null: leaving the key out would mean "the default" to the daemon.
        if let eveningSummary { try c.encode(eveningSummary, forKey: .eveningSummary) }
        else { try c.encodeNil(forKey: .eveningSummary) }
        try c.encode(tz, forKey: .tz)
    }
}

// MARK: - Verbs

public enum PushEnvironmentWire: String, Codable, Equatable, Sendable {
    case sandbox, production
}

extension PushEnvironmentWire {
    /// The APNs environment the installed build was signed for: the `aps-environment` entitlement in
    /// its embedded provisioning profile (`development` -> sandbox, `production` -> production), not
    /// the build configuration (a Release build signed with a development profile talks to the
    /// sandbox). A simulator build has no profile and no APNs token, so it reads as sandbox; a build
    /// with no profile (the App Store removes it) or one that names no environment is production.
    public static func signed(provisioning: Data?, simulator: Bool) -> PushEnvironmentWire {
        if simulator { return .sandbox }
        guard let provisioning, let text = String(data: provisioning, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"), let end = text.range(of: "</plist>") else {
            return .production
        }
        let plist = Data(text[start.lowerBound..<end.upperBound].utf8)
        guard let root = (try? PropertyListSerialization.propertyList(from: plist, format: nil)) as? [String: Any],
              let entitlements = root["Entitlements"] as? [String: Any],
              let aps = entitlements["aps-environment"] as? String else {
            return .production
        }
        return aps == "development" ? .sandbox : .production
    }
}

/// What this build of the app can do. W13's app sends `nseWithdraw: false`.
public struct PushCapabilitiesWire: Codable, Equatable, Sendable {
    public var nseWithdraw: Bool
    public init(nseWithdraw: Bool = false) { self.nseWithdraw = nseWithdraw }
    enum CodingKeys: String, CodingKey { case nseWithdraw = "nse_withdraw" }
}

/// The phone's Apple push token (hex), once iOS has issued one. Mirrors `ClientMsg::RegisterPush`.
public struct ClientRegisterPush: Encodable, Equatable {
    let type_ = "register_push"
    public let apnsToken: String
    public let environment: PushEnvironmentWire
    public let tz: String
    public let capabilities: PushCapabilitiesWire

    public init(apnsToken: String, environment: PushEnvironmentWire, tz: String = TimeZone.current.identifier,
                capabilities: PushCapabilitiesWire = PushCapabilitiesWire()) {
        self.apnsToken = apnsToken
        self.environment = environment
        self.tz = tz
        self.capabilities = capabilities
    }

    enum CodingKeys: String, CodingKey {
        case type_ = "type"
        case apnsToken = "apns_token"
        case environment, tz, capabilities
    }
}

/// Replace this device's notification settings. Mirrors `ClientMsg::SetPushPrefs`.
public struct ClientSetPushPrefs: Encodable, Equatable {
    let type_ = "set_push_prefs"
    public let prefs: PushPrefsWire
    public init(prefs: PushPrefsWire) { self.prefs = prefs }
    enum CodingKeys: String, CodingKey { case type_ = "type", prefs }
}

/// This device's notifications of the last seven days. Mirrors `ClientMsg::PushSentLog`.
public struct ClientPushSentLog: Encodable, Equatable {
    let type_ = "push_sent_log"
    public init() {}
    enum CodingKeys: String, CodingKey { case type_ = "type" }
}

/// What waits on the operator now. Mirrors `ClientMsg::PushWaiting`.
public struct ClientPushWaiting: Encodable, Equatable {
    let type_ = "push_waiting"
    public init() {}
    enum CodingKeys: String, CodingKey { case type_ = "type" }
}

// MARK: - Frames

/// How a notification attempt came out (`PushOutcome` in `src/push/wire.rs`).
public enum PushOutcomeWire: String, Equatable, Sendable {
    case deliveredToApple = "delivered_to_apple"
    case rejectedByApple = "rejected_by_apple"
    case relayUnreachable = "relay_unreachable"
    case heldQuietHours = "held_quiet_hours"
    case coalesced
    case withdrawn
    case skippedResolvedInGrace = "skipped_resolved_in_grace"
    /// An outcome a newer daemon added.
    case other

    /// The words the sent-notifications screen shows.
    public var label: String {
        switch self {
        case .deliveredToApple: return "Delivered to Apple"
        case .rejectedByApple: return "Rejected by Apple"
        case .relayUnreachable: return "Relay unreachable"
        case .heldQuietHours: return "Held for quiet hours"
        case .coalesced: return "Coalesced into a summary"
        case .withdrawn: return "Withdrawn"
        case .skippedResolvedInGrace: return "Skipped: resolved during grace delay"
        case .other: return "Other"
        }
    }
}

public struct PushSentEntryWire: Equatable, Identifiable, Sendable {
    public let ts: Date
    public let kind: String
    public let host: String
    public let title: String
    public let body: String
    public let outcome: PushOutcomeWire

    public var id: String { "\(ts.timeIntervalSince1970)|\(kind)|\(host)|\(title)|\(body)|\(outcome.rawValue)" }

    public init(ts: Date, kind: String, host: String, title: String, body: String, outcome: PushOutcomeWire) {
        self.ts = ts
        self.kind = kind
        self.host = host
        self.title = title
        self.body = body
        self.outcome = outcome
    }
}

public struct PushWaitingItemWire: Equatable, Identifiable, Sendable {
    public let itemRef: String
    public let kind: PushKindWire
    public let host: String
    /// `Job 3f9a1c2e`, `PR #4821`; absent for a decision.
    public let ref: String?

    public var id: String { itemRef }

    public init(itemRef: String, kind: PushKindWire, host: String, ref: String?) {
        self.itemRef = itemRef
        self.kind = kind
        self.host = host
        self.ref = ref
    }
}

public enum HostClassWire: String, Equatable, Sendable {
    case work, personal
}

/// The reply to `register_push` and `set_push_prefs`.
public struct PushStatusWire: Equatable, Sendable {
    public let prefs: PushPrefsWire
    /// Read-only here: only a shell on the primary changes it. An absent host is `work`.
    public let hostClasses: [String: HostClassWire]
    /// Read-only; always holds `Carefeed`.
    public let workOwners: [String]
    public let lastOkAt: Date?
    public let failingSince: Date?

    public init(prefs: PushPrefsWire, hostClasses: [String: HostClassWire], workOwners: [String],
                lastOkAt: Date?, failingSince: Date?) {
        self.prefs = prefs
        self.hostClasses = hostClasses
        self.workOwners = workOwners
        self.lastOkAt = lastOkAt
        self.failingSince = failingSince
    }
}

extension ServerMsg {
    /// The push frames, or `nil` for any other type. Tolerant: an unknown field is ignored and an
    /// unknown outcome reads as `other`.
    static func decodePushFrame(type_: String, data: Data) -> ServerMsg? {
        guard type_ == "push_sent_log" || type_ == "push_waiting" || type_ == "push_status" else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .unknown }
        switch type_ {
        case "push_sent_log":
            let rows = json["entries"] as? [[String: Any]] ?? []
            return .pushSentLog(rows.compactMap { row in
                guard let ts = (row["ts"] as? String).flatMap(PushWireDates.parse),
                      let kind = row["kind"] as? String, let host = row["host"] as? String,
                      let title = row["title"] as? String, let body = row["body"] as? String
                else { return nil }
                let outcome = (row["outcome"] as? String).flatMap(PushOutcomeWire.init(rawValue:)) ?? .other
                return PushSentEntryWire(ts: ts, kind: kind, host: host, title: title, body: body, outcome: outcome)
            })
        case "push_waiting":
            let rows = json["items"] as? [[String: Any]] ?? []
            let items: [PushWaitingItemWire] = rows.compactMap { row in
                guard let ref = row["item_ref"] as? String,
                      let kind = (row["kind"] as? String).flatMap(PushKindWire.init(rawValue:)),
                      let host = row["host"] as? String
                else { return nil }
                return PushWaitingItemWire(itemRef: ref, kind: kind, host: host, ref: row["ref"] as? String)
            }
            return .pushWaiting(items: items, badge: (json["badge"] as? NSNumber)?.intValue ?? items.count)
        default:
            guard let prefsJSON = json["prefs"],
                  let prefsData = try? JSONSerialization.data(withJSONObject: prefsJSON),
                  let prefs = try? JSONDecoder().decode(PushPrefsWire.self, from: prefsData)
            else { return .unknown }
            let classes = (json["host_classes"] as? [String: String] ?? [:])
                .reduce(into: [String: HostClassWire]()) { $0[$1.key] = HostClassWire(rawValue: $1.value) ?? .work }
            return .pushStatus(PushStatusWire(
                prefs: prefs,
                hostClasses: classes,
                workOwners: json["work_owners"] as? [String] ?? [],
                lastOkAt: (json["last_ok_at"] as? String).flatMap(PushWireDates.parse),
                failingSince: (json["failing_since"] as? String).flatMap(PushWireDates.parse)))
        }
    }
}

enum PushWireDates {
    static func parse(_ s: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = fractional.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }
}
